#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-fetchcache.t - the fetch cache: what it fetches from, how
long it keeps what, and what it deliberately does not do

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
use Provisioner::Recipe::fetchcache();

my $DOMAIN = 'fetchcache.test.test';

sub generated {
    my (%extra) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'fetchcache', distro => 'ubuntu' )->new(
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
        resolvers    => [ '192.168.1.253', '8.8.8.8' ],
        %extra,
    );

    $recipe->generate_files( $dir, %vars );
    return ( File::Slurper::read_text("$dir/fetchcache.nginx.conf"), $recipe, $dir );
}

# The hosts the vhost will fetch from, read back out of the capture every
# location uses -- not out of the whole file, where the URL shapes name hosts too.
sub allowed {
    my ($vhost) = @_;
    my %hosts;
    foreach my $group ( $vhost =~ m/\(\?<fetchcache_host>([^)]*)\)/g ) {
        $hosts{s/\\//gr}++ for split( /(?<!\\)[|]/, $group );
    }
    return [ sort keys %hosts ];
}

subtest 'the upstreams: every default kept when an operator names another' => sub {
    my ($defaults) = generated();
    my @defaults = @{ allowed($defaults) };
    ok( ( grep { $_ eq 'www.cpan.org' } @defaults ) && ( grep { $_ eq 'github.com' } @defaults ), 'CPAN and GitHub by default' );

    # The default is on each host rather than on the map, so an operator adding
    # one does not replace the lot -- the ufw rate_limits trap.
    my ($added) = generated( upstreams => { 'nodejs.org' => 1 } );
    is_deeply( allowed($added), [ sort @defaults, 'nodejs.org' ], 'naming another adds it to the defaults' );

    my ($removed) = generated( upstreams => { 'github.com' => 0 } );
    is_deeply( allowed($removed), [ grep { $_ ne 'github.com' } @defaults ], 'and naming a default false takes it away' );
};

subtest 'what the vhost will not accept' => sub {

    # They are written into it as a regex.
    like( exception { generated( upstreams => { 'evil.test/x|.*' => 1 } ) }, qr/plain host names/, 'a host that is not a plain DNS name' );

    my %none = map { $_ => 0 } @{ allowed( ( generated() )[0] ) };
    like( exception { generated( upstreams => \%none ) }, qr/no upstreams turned on/, 'no hosts at all, which would fetch nothing' );

    like( exception { generated( resolvers => [] ) }, qr/needs resolvers/, 'and no resolvers to look them up with' );

    like( exception { generated( resolvers => [ '127.0.0.1', '::1' ] ) }, qr/needs resolvers/, 'or none it can reach' );
};

subtest 'each kind of URL gets its own freshness, and its own redirect handling' => sub {
    my ($vhost) = generated( fresh_index => '5m', fresh_immutable => '30d', fresh_default => '2h' );

    foreach my $class ( [ index => '5m' ], [ immutable => '30d' ], [ default => '2h' ] ) {
        my ( $name, $fresh ) = @$class;

        # The location for the kind, then its @follow, each keeping only a 200
        # for as long as that kind is fresh.
        like( $vhost, qr/location ~ "[^"]+" \{\n\s+proxy_cache_valid 200 \Q$fresh\E;\n\s+error_page 301 302 303 307 308 = \@follow_$name;/, "$name: fresh for $fresh, redirects followed" );
        like( $vhost, qr/location \@follow_$name \{.*?proxy_cache_valid 200 \Q$fresh\E;.*?proxy_pass \$fetchcache_location;/s,              "$name: and a followed redirect is kept as long" );
    }

    # Most specific first: nginx takes the first regex location that matches.
    my @order = $vhost =~ m/= \@follow_(\w+);\n\s+proxy_pass https/g;
    is_deeply( \@order, [qw{index immutable default}], 'in that order' );
};

subtest 'a followed redirect is kept under the URL the guest asked for, and goes nowhere else' => sub {
    my ($vhost) = generated();

    like( $vhost, qr/^\s+proxy_cache_key \$request_uri;$/m, 'the key is the request, which the internal redirect does not change' );
    like( $vhost, qr/^\s+recursive_error_pages on;$/m,      'a second hop is followed too' );

    my ($guard) = $vhost =~ m/if \(\$fetchcache_location !~ "\^https:\/\/\(\?:([^)]*)\)\/"\)/;
    ok( defined $guard, 'a redirect is checked before it is followed' ) or return;
    is_deeply( [ sort map { s/\\//gr } split( /(?<!\\)[|]/, $guard ) ], allowed($vhost), 'against the same hosts, and only over https' );
};

subtest 'upstream is trusted as little as possible' => sub {
    my ($vhost) = generated();

    like( $vhost, qr/^\s+proxy_ssl_verify on;$/m,                                 'its certificate is verified' );
    like( $vhost, qr/^\s+proxy_ssl_server_name on;$/m,                            'for the name that was asked for' );
    like( $vhost, qr/^\s+proxy_set_header Authorization "";$/m,                   'no credentials go to it' );
    like( $vhost, qr/^\s+proxy_set_header Cookie "";$/m,                          'nor cookies' );
    like( $vhost, qr/^\s+proxy_ignore_headers [^;]*\bCache-Control\b/m,           'and its caching headers do not decide what is kept' );
    like( $vhost, qr/^\s+proxy_cache_use_stale [^;]*\berror\b[^;]*\bhttp_503\b/m, 'what it had is served when upstream fails' );
    like( $vhost, qr/^\s+resolver 192\.168\.1\.253 8\.8\.8\.8 ipv6=off;$/m,       'looked up through the resolvers it was given' );

    # The fleet's list, as a real ipmap.cfg has it: a loopback for guests that
    # run the pdns recursor, which this one does not, and an IPv6 address nginx
    # is told not to use.  Measured on a guest: nginx rotated onto 127.0.0.1
    # and every few lookups was a refused connection.
    my ($fleet) = generated( resolvers => [qw{127.0.0.1 192.168.1.254 8.8.8.8 2600:1700::1}] );
    like( $fleet, qr/^\s+resolver 192\.168\.1\.254 8\.8\.8\.8 ipv6=off;$/m, 'and only the ones it can reach' );

    # github.com sends five kilobytes of headers, which the default buffer turned
    # into a 502 before the redirect in them was read.
    like( $vhost, qr/^\s+proxy_buffer_size 16k;$/m, 'with room for GitHub headers' );
};

subtest 'a copy is removed for want of room, never for its age' => sub {
    my ($vhost) = generated();
    my ($path)  = $vhost =~ m/^(proxy_cache_path [^;]*);$/m;
    ok( defined $path, 'there is a store' ) or return;

    # The copy nobody has asked for in a year is the pinned version upstream may
    # no longer have, so age alone must not take it.
    like( $path, qr/ inactive=100y\b/, 'kept however long since anybody asked for it' );
    like( $path, qr/ max_size=20g\b/,  'until the store is full' );
    like( $path, qr/ min_free=5g\b/,   'or the disk under it nearly is' );

    my ($off) = generated( min_free_gb => 0 );
    unlike( $off, qr/min_free=/, 'and min_free can be turned off' );
};

subtest 'on a port of its own, it shares a guest with a package mirror' => sub {
    my ( $vhost, $recipe, $dir ) = generated( port => 8080 );

    like( $vhost,                                               qr/^\s+listen 8080 backlog=32768;$/m,        'it listens where it was told' );
    like( $vhost,                                               qr/^\s+listen \[::\]:8080 backlog=32768;$/m, 'on IPv6 too' );
    like( File::Slurper::read_text("$dir/fetchcache_ufw.conf"), qr{^ports=8080/tcp$}m,                       'with a firewall profile for that port' );
    is_deeply( { $recipe->rate_limits( port => 8080 ) }, { 8080 => 1024 }, 'and a limit on it' );
    is_deeply( { $recipe->rate_limits() },               { 80   => 1024 }, 'which is 80 when nothing says otherwise' );

    # Measured on a guest: on one port, nginx refuses a second backlog outright
    # and ignores the second server for names the first already has -- which
    # both have, the guest name and its address.  So the mirror and the cache
    # can share a guest only if they share no port.
    my $mirror = tempdir( CLEANUP => 1 );
    Provisioner::Cookbook->load( 'aptmirror', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $mirror,
        distro        => 'ubuntu',
    )->generate_files( $mirror, domain => $DOMAIN, main_ip => '192.168.1.9', full_aliases => [], install_dir => '/opt/domains', script_dir => '/root/bin', releases => ['noble'] );

    my %ports;
    foreach my $conf ( $vhost, File::Slurper::read_text("$mirror/aptmirror.nginx.conf") ) {
        my %mine = map { $_ => 1 } $conf =~ m/^\s+listen (?:\[::\]:)?(\d+)/mg;
        $ports{$_}++ for keys %mine;
    }
    is_deeply( [ grep { $ports{$_} > 1 } sort keys %ports ], [], 'and then it and the mirror share no port' );
};

subtest 'the vhost answers for the address, not only the name' => sub {
    my ($vhost) = generated();

    like( $vhost, qr/^\s+server_name \Q$DOMAIN\E 192\.168\.1\.9 www\.\Q$DOMAIN\E;$/m, 'the address is a server_name' );
    unlike( $vhost, qr/default_server/,             'without claiming default_server' );
    unlike( $vhost, qr/listen 443|ssl_certificate/, 'plain HTTP, as the package mirror is' );
    like( $vhost, qr{^\s+location = /fetchcache-status \{$}m, 'says it is there' );
    like( $vhost, qr{^\s+location / \{\n\s+return 404;}m,     'and fetches nothing it was not told to' );
};

# The shapes are PCRE nginx evaluates; these ones read the same in perl, so what
# each URL is taken for can be asked here rather than on a guest.
subtest 'which kind each URL recipes fetch is taken for' => sub {
    my @CLASSES = @Provisioner::Recipe::fetchcache::CLASSES;
    my $kind    = sub {
        my ($path) = @_;
        foreach my $class (@CLASSES) {
            return $class->{name} if !defined $class->{shape} || "/$path" =~ m{^/(?=(?:$class->{shape}))};
        }
        return 'none';
    };

    my $sha = '2082d13bb195f3203d41a308b89417426a7deca1';
    foreach my $case (
        [ 'www.cpan.org/modules/02packages.details.txt.gz'                           => 'index' ],
        [ 'fastapi.metacpan.org/v1/download_url/Sys::Virt'                           => 'index' ],
        [ 'api.github.com/repos/deuxfleurs-org/garage/tags'                          => 'index' ],
        [ 'github.com/o/r/releases/latest/download/x.tgz'                            => 'index' ],
        [ 'www.cpan.org/authors/id/D/DA/DANBERR/Sys-Virt-v10.0.0.tar.gz'             => 'immutable' ],
        [ 'github.com/o/r/releases/download/v1.0/x.tgz'                              => 'immutable' ],
        [ "github.com/o/r/archive/$sha.tar.gz"                                       => 'immutable' ],
        [ 'github.com/o/r/archive/refs/tags/v1.0.tar.gz'                             => 'immutable' ],
        [ "codeload.github.com/prabirshrestha/async.vim/tar.gz/$sha"                 => 'immutable' ],
        [ 'garagehq.deuxfleurs.fr/_releases/v1.0.1/x86_64-unknown-linux-musl/garage' => 'immutable' ],
        [ 'download.imagemagick.org/archive/releases/ImageMagick-7.1.1-47.tar.xz'    => 'immutable' ],

        # These move, and a year of the first copy would be a year of the wrong
        # file.
        [ 'www.cpan.org/authors/id/D/DA/DANBERR/CHECKSUMS'         => 'default' ],
        [ 'github.com/o/r/archive/refs/heads/master.tar.gz'        => 'default' ],
        [ 'codeload.github.com/o/r/tar.gz/refs/heads/master'       => 'default' ],
        [ 'raw.githubusercontent.com/nvm-sh/nvm/master/install.sh' => 'default' ],
    ) {
        my ( $path, $want ) = @$case;
        is( $kind->($path), $want, "$path is $want" );
    }
};

subtest 'nothing depends on it, and it salvages nothing' => sub {
    my ( undef, $recipe ) = generated();

    is_deeply( [ sort keys %{ { $recipe->required_recipes() } } ], ['nginx'], 'it needs nginx, and nothing else' );

    is_deeply( [ $recipe->remote_files( '/opt/domains', $DOMAIN ) ], [], 'what it keeps is not salvaged off the guest, being re-fetchable' );
    is_deeply( [ $recipe->restores() ],                              [], 'nor put back onto a rebuilt one' );
    is_deeply( [ $recipe->datadirs() ],                              [], 'and it owns nothing under install_dir' );

    foreach my $name ( Provisioner::Cookbook->names() ) {
        my %theirs = eval { Provisioner::Cookbook->load($name)->required_recipes() };
        ok( !exists $theirs{fetchcache}, "$name does not drag a cache host into its dependency graph" );
    }
};

Test::NoWarnings::had_no_warnings();

done_testing;
