#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-aptmirror.t - the mirror host: what it writes, and what it
deliberately does not

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();

my $DOMAIN = 'aptmirror.test.test';

sub generated {
    my (%extra) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'aptmirror', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    my %vars = (
        domain       => $DOMAIN,
        main_ip      => '192.168.1.9',
        full_aliases => ["www.$DOMAIN"],
        install_dir  => '/opt/domains',
        script_dir   => '/root/bin',
        releases     => ['noble'],
        %extra,
    );

    my @written = $recipe->generate_files( $dir, %vars );
    return ( $dir, \@written, $recipe, \%vars );
}

sub slurp { my ( $dir, $file ) = @_; return File::Slurper::read_text("$dir/$file") }

subtest 'mirror.list says what to mirror and where to put it' => sub {
    my ( $dir, undef ) = generated( pockets => [ q{}, '-security' ], arches => [qw{amd64 arm64}], components => ['main'] );
    my $conf = slurp( $dir, 'aptmirror.mirror.list' );

    like( $conf, qr{^set base_path\s+/var/spool/apt-mirror$}m, 'the spool is written out rather than left to the packaged default' );

    # Every release crossed with every pocket, on every architecture.  A missing
    # -security line is a mirror that quietly lacks security updates, which is
    # the whole class of problem this recipe exists to remove.
    foreach my $suite (qw{noble noble-security}) {
        foreach my $arch (qw{amd64 arm64}) {
            like( $conf, qr{^deb-\Q$arch\E \S+ \Q$suite\E main$}m, "$suite on $arch" );
        }
    }

    unlike( $conf, qr/^deb-src/m, 'and no sources, which would roughly double it' );
    like( $conf, qr/^set run_postmirror 1$/m, 'the post-sync hook is enabled, or clean.sh never runs and the spool only grows' );
};

subtest 'sources are mirrored when asked for' => sub {
    my ( $dir, undef ) = generated( sources => 1, components => ['main'] );
    like( slurp( $dir, 'aptmirror.mirror.list' ), qr/^deb-src \S+ noble main$/m, 'a deb-src line per suite' );
};

subtest 'the sync is a unit systemd will not kill' => sub {
    my ( $dir, undef ) = generated();
    my $unit = slurp( $dir, 'aptmirror.service' );

    # The default is ninety seconds.  A killed sync leaves a partial spool that
    # nginx serves as though it were a mirror, so apt 404s per package and falls
    # through to the archive -- it degrades quietly rather than failing.
    like( $unit, qr/^TimeoutStartSec=0$/m,             'no start timeout' );
    like( $unit, qr/^Type=oneshot$/m,                  'a oneshot' );
    like( $unit, qr{^ExecStart=/usr/bin/apt-mirror$}m, 'running apt-mirror' );
};

subtest 'the refresh goes through that same unit' => sub {
    my ( $dir, undef ) = generated( refresh => '30 4 * * 6' );
    my $cron = slurp( $dir, 'aptmirror.cron' );

    like( $cron, qr/^30 4 \* \* 6 root systemctl start --no-block apt-mirror\.service$/m, 'on the configured schedule' );

    # Starting the unit rather than running apt-mirror is what stops a refresh
    # landing mid-sync from running a second one over the same spool: systemd
    # will not run two instances, so it queues.
    unlike( $cron, qr{^\S+ \S+ \S+ \S+ \S+ root /usr/bin/apt-mirror}m, 'never apt-mirror directly' );

    # cron runs jobs under dash, which reads &> as a background & and a
    # redirection -- see templates/files/backupdestination.cron.tt.
    unlike( $cron, qr/&>/, 'and nothing redirects with &>' );
};

subtest 'the vhost answers for the address, not only the name' => sub {
    my ( $dir, undef ) = generated();
    my $vhost = slurp( $dir, 'aptmirror.nginx.conf' );

    # A guest fetching packages reaches this by address: it runs cloud-init
    # before it has a resolver, so the request arrives with a Host that is an IP
    # and would otherwise match no server.
    like( $vhost, qr/^\s+server_name \Q$DOMAIN\E 192\.168\.1\.9 www\.\Q$DOMAIN\E;$/m, 'the address is a server_name' );

    # Claiming default_server would mean deleting the packaged default site
    # first, since two of them is a configuration nginx refuses.
    unlike( $vhost, qr/default_server/, 'without claiming default_server' );

    like( $vhost, qr{^\s+location /ubuntu/ \{$}m,                                             'served at the path the distro tells guests to use' );
    like( $vhost, qr{^\s+alias /var/spool/apt-mirror/mirror/archive\.ubuntu\.com/ubuntu/;$}m, 'out of where apt-mirror actually puts it' );
    like( $vhost, qr{^\s+location = /mirror-status \{$}m,                                     'and says when it last finished a sync' );

    unlike( $vhost, qr/listen 443|ssl_certificate/, 'no TLS: the guest certificate is self-signed and apt will not fetch through one' );
};

subtest 'where the copy lands follows from the upstream' => sub {

    # apt-mirror lays a spool out under the upstream host, so this cannot be
    # written down -- and the vhost and the fragment have to name the same one.
    my ( $dir, undef, $recipe, $vars ) = generated( upstream => 'http://mirror.example.test/ubuntu-ports', spool => '/srv/mirror' );

    like( slurp( $dir, 'aptmirror.nginx.conf' ), qr{alias /srv/mirror/mirror/mirror\.example\.test/ubuntu-ports/;}, 'the alias follows upstream and spool' );

    like(
        exception { generated( upstream => 'mirror.example.test' ) },
        qr/upstream must be a URL/,
        'and an upstream that is not a URL is refused, rather than making a nonsense path'
    );
};

subtest 'nothing depends on it, and it salvages nothing' => sub {
    my ( undef, undef, $recipe ) = generated();

    my %required = $recipe->required_recipes();
    is_deeply( [ sort keys %required ], ['nginx'], 'it needs nginx to serve the copy, and nothing else' );

    # Salvage lands in the domain's data directory and from there into
    # data.tar.gz and every backup taken of it.  This is hundreds of gigabytes
    # of files that exist on the archive and are re-fetchable by definition, so
    # a rebuilt mirror syncs again instead.
    is_deeply( [ $recipe->remote_files( '/opt/domains', $DOMAIN ) ], [], 'the spool is not salvaged off the guest' );
    is_deeply( [ $recipe->restores() ],                              [], 'and nothing is put back onto a rebuilt one' );
    is_deeply( [ $recipe->datadirs() ],                              [], 'and it owns nothing under install_dir, which the data target walks recursively' );

    # The other half of decision 5: no recipe may require this one.
    foreach my $name ( Provisioner::Cookbook->names() ) {
        my $class  = Provisioner::Cookbook->load($name);
        my %theirs = eval { $class->required_recipes() };
        ok( !exists $theirs{aptmirror}, "$name does not drag a mirror host into its dependency graph" );
    }
};

Test::NoWarnings::had_no_warnings();

done_testing;
