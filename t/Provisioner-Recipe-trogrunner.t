#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-trogrunner.t - a guest that can build guests: what it is
handed, what it must never be handed, and what it does with no checkout

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();

my $DOMAIN  = 'runner.test.test';
my $INSTALL = '/opt/domains';

sub built {
    my (%extra) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'trogrunner', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    my %vars = (
        domain      => $DOMAIN,
        install_dir => $INSTALL,
        script_dir  => '/root/bin',
        admin_user  => 'doge',
        admin_email => 'doge@test.test',
        main_ip     => '192.168.1.50',
        %extra,
    );

    $recipe->generate_files( $dir, %vars );
    return ( $dir, $recipe, \%vars );
}

sub slurp { my ( $dir, $file ) = @_; return File::Slurper::read_text("$dir/$file") }

my %HYDRA = (
    hydra => {
        libvirt_uri => 'qemu+ssh://runner@hydra.test.test:2222/system',
        pool_path   => '/pool/vm-disks/runner',
        pool_name   => 'runner_disks',
        partition   => '/machine/runner',
    },
);

subtest 'the four sections of an ipmap Config::Simple will read back' => sub {
    my ($dir) = built(
        config => {
            gateway     => '192.168.1.254',
            ips         => { 'g.test.test' => '192.168.1.60' },
            aliases     => { 'g.test.test' => 'www.test.test' },
            nameservers => { ns1           => 'ns1.test.test' },
            addresses   => '192.168.1.60-192.168.1.99',
            cidr        => '192.168.1.0/24',
        },
    );
    my $cfg = slurp( $dir, 'trogrunner.ipmap.cfg' );

    like( $cfg, qr/^\[ip_pool\]$/m,                                'the pool section' );
    like( $cfg, qr/^addresses=192\.168\.1\.60-/m,                  'with the range it was given' );
    like( $cfg, qr/^\[ips\]\ng\.test\.test=192\.168\.1\.60$/m,     'assignments' );
    like( $cfg, qr/^\[aliases\]\ng\.test\.test=www\.test\.test$/m, 'aliases' );
    like( $cfg, qr/^\[nameservers\]\nns1=ns1\.test\.test$/m,       'nameservers' );
    like( $cfg, qr/^\[global\]$/m,                                 'and the global block' );

    # The runner administers what it builds as whoever administers it, which is
    # what _global already says about this guest -- so nobody has to write it
    # down twice.
    like( $cfg, qr/^admin_user=doge$/m,              'the admin comes from the guest own' );
    like( $cfg, qr/^admin_email=doge\@test\.test$/m, 'and so does the address' );
    like( $cfg, qr/^ip=192\.168\.1\.50$/m,           'and the address it serves payloads from' );
};

subtest 'a secret in the runner recipes never becomes a password in a file' => sub {

    # bin/new_config resolves every secret: in the whole configuration before a
    # recipe is built, so a secret: written in here would arrive resolved and be
    # dumped into recipes.yaml, into data.tar.gz and into every backup taken of
    # this domain.  store: is what passes through untouched.
    my ($dir) = built(
        recipes => {
            'g.test.test' => {
                nginx => { cert_password => 'store:g.test.test/tls/password' },
                mail  => { names         => { andy => { password => 'store:mail/andy/password' } } },
            },
        },
    );

    my $yaml = slurp( $dir, 'trogrunner.recipes.yaml' );
    ok( index( $yaml, 'secret:g.test.test/tls/password' ) >= 0, 'store: comes back out as secret:' )  or diag $yaml;
    ok( index( $yaml, 'secret:mail/andy/password' ) >= 0,       'however deep it was nested' )        or diag $yaml;
    ok( index( $yaml, 'store:' ) < 0,                           'and nothing is left saying store:' ) or diag $yaml;

    # What the runner gets is a reference, exactly as a hand-written
    # recipes.yaml would hold -- so nothing here is a password even though
    # Trog::Secrets would have resolved one had it been spelled the usual way.
    my $refs = grep { index( $_, 'secret:' ) >= 0 } split( "\n", $yaml );
    is( $refs, 2, 'both of them, and nothing else that could be a value' );
};

subtest 'a hypervisor block is written whole, and taken apart for ssh' => sub {
    my ( $dir, $recipe, $vars ) = built( hypervisors => \%HYDRA, hypervisor_access => 'least' );
    my $conf = slurp( $dir, 'trogrunner.hypervisors.conf' );

    like( $conf, qr/^\[hydra\]$/m,                              'one block per hypervisor' );
    like( $conf, qr/^pool_path\s+= \/pool\/vm-disks\/runner$/m, 'the pool it is confined to' );
    like( $conf, qr/^pool_name\s+= runner_disks$/m,             'named as well as pathed, or libvirt ignores the path' );
    like( $conf, qr/^partition\s+= \/machine\/runner$/m,        'and the slice its guests land in' );

    # Not for the fleet file -- for ssh-keyscan.  libvirt's qemu+ssh transport
    # verifies host keys where Net::OpenSSH::More does not, so an unseeded
    # known_hosts is a hypervisor that refuses on first contact while a plain
    # ssh to the same machine works.
    my %got = $recipe->validate(%$vars);
    is( $got{hypervisors}{hydra}{ssh_host}, 'hydra.test.test', 'the host out of the URI' );
    is( $got{hypervisors}{hydra}{ssh_user}, 'runner',          'the user' );
    is( $got{hypervisors}{hydra}{ssh_port}, 2222,              'and the port, when it is not 22' );

    my $fragment = $recipe->render(%$vars);
    like( $fragment, qr/ssh-keyscan -p '2222' 'hydra\.test\.test'/, 'which is what gets scanned' );

    # Into the home ssh will read, asked of passwd, rather than into the domain
    # directory -- which is a home only when the domain names a service user.
    like( $fragment, qr/getent passwd 'doge'/, 'the home is asked for rather than assumed' );
    like( $fragment, qr{known_hosts},          'and that is where the host keys go' );
    unlike( $fragment, qr{\Q$INSTALL/$DOMAIN\E/\.ssh/known_hosts}, 'not beside the key, where ssh would never read them' );
};

subtest 'a hypervisor we could not get a shell on is refused here, not on the guest' => sub {

    # Trog::HV's rule: a remote hypervisor whose transport gives no shell is
    # half usable, and the missing half is not optional.  Better said while
    # somebody is reading the output than an hour into a build.
    like(
        exception {
            built( hypervisors => { far => { libvirt_uri => 'qemu+tcp://far.test.test/system' } } );
        },
        qr/needs an ssh transport/,
        'named, with the URI it should have had'
    );
};

subtest 'no fleet is a legitimate answer' => sub {
    my ( $dir, $recipe, $vars ) = built();

    # It means "this machine", which is what libvirt does when nothing says
    # otherwise, and what a runner that is its own hypervisor wants.  Rendered
    # anyway; the fragment is what declines to install it.
    is( slurp( $dir, 'trogrunner.hypervisors.conf' ), q{}, 'the file renders empty' );
    unlike( $recipe->render(%$vars), qr/hypervisors\.conf/, 'and nothing installs it' );
};

subtest 'Sys::Virt is pinned, and pinned before anything resolves dependencies' => sub {
    my ( undef, $recipe, $vars ) = built( libvirt_version => '10.0.0' );
    my $fragment = $recipe->render(%$vars);

    like( $fragment, qr/\QSys::Virt\E\@10\.0\.0/, 'pinned to what was asked for' );

    # The ordering is the whole point.  Left to the dependency list cpanm takes
    # the newest Sys::Virt, whose Makefile.PL wants a libvirt-dev far newer
    # than a noble guest has -- and says so forty minutes in, in a message
    # about pkg-config rather than about ordering.
    # The queued lines only.  Every one of these words appears in the comment
    # above the line it explains, so a search of the whole fragment finds the
    # prose rather than the command and passes whatever the order is.
    my @lines  = grep { index( $_,         'queue_postrun_task' ) >= 0 } split( "\n", $fragment );
    my ($virt) = grep { index( $lines[$_], 'Sys::Virt' ) >= 0 } 0 .. $#lines;
    my ($deps) = grep { index( $lines[$_], 'authordeps' ) >= 0 } 0 .. $#lines;
    ok( defined $virt && defined $deps && $virt < $deps, 'and queued ahead of the first authordeps' )
      or diag "Sys::Virt at line $virt, authordeps at line $deps";

    # authordeps before listdeps for the same class of reason: dist.ini names
    # plugins, and dzil cannot read its own configuration to answer listdeps
    # until they are installed.
    my ($list) = grep { index( $lines[$_], 'listdeps' ) >= 0 } 0 .. $#lines;
    ok( defined $list && $deps < $list, 'authordeps ahead of listdeps' );
};

subtest 'the perl is found at run time, and found somewhere that exists' => sub {
    my ( undef, $recipe, $vars ) = built();
    my @queued = grep { index( $_, 'queue_postrun_task' ) >= 0 } split( "\n", $recipe->render(%$vars) );
    my @cpanm  = grep { index( $_, 'cpanm' ) >= 0 } @queued;

    ok( scalar @cpanm, 'something is queued that installs from CPAN' );
    foreach my $line (@cpanm) {

        # Measured on a guest: resolving this at makefile time gave dirname an
        # empty string, because the perl recipe had not built anything yet, and
        # every task in the queue read ./cpanm.  The $ has to survive make and
        # the shell so that the expansion happens when the task runs.
        ok( index( $line, 'readlink -f /root/bin/cpanm' ) >= 0, 'the bin directory is resolved from a path that will exist' );
        ok( index( $line, '\$$(dirname' ) >= 0,                 'and resolved when the task runs rather than when it is queued' );

        # /root/bin because build_latest_perl.sh links there unconditionally.
        # The other place it links is the home of whoever the perl is for, and
        # that is the domain directory only when the domain names a service
        # user -- which this recipe does not require.  perl.tt was fixed for
        # the same assumption.
        ok( index( $line, "$INSTALL/$DOMAIN/bin/cpanm" ) < 0, 'not through a home directory this domain may not have' );
    }
};

subtest 'an unnamed libvirt version is asked of the guest rather than guessed' => sub {
    my ( undef, $recipe, $vars ) = built();
    my $fragment = $recipe->render(%$vars);

    # A recipe cannot load Trog::HV to ask a hypervisor, so a written-down
    # default would be a guess that goes stale.  The guest can answer for
    # itself, and does -- at makefile time, so post_install.sh names the
    # version rather than a command.
    like( $fragment, qr/pkg-config --modversion libvirt/,      'the guest is asked' );
    like( $fragment, qr/there is no Sys::Virt version to pin/, 'and the build stops if it cannot answer' );
};

subtest 'the checkout is optional, which is the case koan needs' => sub {
    my ( undef, $with, $wvars ) = built();
    like( $with->render(%$wvars), qr{git clone --branch 'master'}, 'cloned by default' );

    my ( undef, $without, $ovars ) = built( checkout => 0, deps_from => ['/srv/code/trog-provisioner'] );
    my $fragment = $without->render(%$ovars);

    unlike( $fragment, qr/git clone/, 'and not at all when the runner manages its own' );
    like( $fragment, qr{cd '/srv/code/trog-provisioner' && .*dzil authordeps}, 'deps come from where it says instead' );
    like( $fragment, qr{cd '/srv/code/trog-provisioner' && .*dzil listdeps},   'both halves of them' );
};

subtest 'the checkout cannot be the domain directory' => sub {

    # service_user makes that directory before the fragment runs, and git clone
    # refuses a target that is not empty -- so this would fail on the guest,
    # after the packages, in a way that reads as a git problem.
    like(
        exception { built( checkout_dir => '.' ) },
        qr/will not drop a repo into the domain directory/,
        'refused while somebody is still reading the output'
    );
};

subtest 'a path meant to be under the domain directory has to be' => sub {

    # `store: /etc/trog-provisioner/secrets.kdbx` is the obvious thing to write
    # and means something else: it renders under the domain directory anyway,
    # as //etc/..., and fails as a missing file rather than as a mistake.
    like( exception { built( store        => '/etc/trog-provisioner/secrets.kdbx' ) }, qr/cannot start with a slash/, 'an absolute store is refused' );
    like( exception { built( store        => '../../etc/secrets.kdbx' ) },             qr/climbs out of it/,          'and so is one that climbs out' );
    like( exception { built( checkout_dir => '/srv/code' ) },                          qr/cannot start with a slash/, 'the same for the checkout' );

    # Only when there is a checkout to put anywhere.  A runner that manages its
    # own repositories never uses the field.
    my ( undef, $recipe, $vars ) = built( checkout => 0, checkout_dir => '/srv/code' );
    ok( $recipe->render(%$vars), 'and not checked at all when nothing is being cloned' );
};

subtest 'the key is declared always, and never salvaged' => sub {
    my ( undef, $recipe ) = built();

    my %secrets = $recipe->guest_secrets( $INSTALL, $DOMAIN );
    my ($path) = keys %secrets;
    is( $path,                 "$INSTALL/$DOMAIN/.ssh/id_ed25519",                  'one key, where ssh will look for it' );
    is( $secrets{$path}{mode}, '0600',                                              'kept to itself, which ssh insists on' );
    is( $secrets{$path}{ref},  "secret:trogrunner/$DOMAIN-hypervisor-key/password", 'held in the store, not in the domain directory' );

    # Unconditional because this is a class method and cannot see
    # hypervisor_access -- which is not a hole, because what that setting
    # decides is whether bin/provision writes the public half into anybody's
    # authorized_keys.  A key no machine trusts opens nothing.
    my %none = $recipe->guest_secrets( $INSTALL, $DOMAIN );
    is_deeply( [ sort keys %none ], [ sort keys %secrets ], 'the same with or without access configured' );

    # The reason remote_skip exists: a secret salvaged off a guest lands in the
    # domain directory and from there into every backup taken of it.
    my @skip = $recipe->remote_skip();
    ok( ( grep { $_ eq 'id_ed25519' } @skip ), 'and excluded from the salvage' );

    # The other thing that must never come off a guest into a backup of it.
    ok( ( grep { $_ eq 'secrets.kdbx' } @skip ), 'and so is the runner own store' );
};

subtest 'what the block asks for by way of hypervisor access' => sub {
    my ( undef, $recipe ) = built();

    # bin/provision and bin/destroy read this rather than restating the
    # defaults, so that there is one place saying what none means.
    is_deeply( { $recipe->grant( {} ) },                                                      {}, 'nothing, by default' );
    is_deeply( { $recipe->grant(undef) },                                                     {}, 'and nothing for a domain that does not run the recipe at all' );
    is_deeply( { $recipe->grant( { hypervisor_access => 'none', hypervisors => \%HYDRA } ) }, {}, 'nor when it is switched off with hypervisors named' );

    my %grant = $recipe->grant( { hypervisor_access => 'least', hypervisors => \%HYDRA } );
    is( $grant{access},   'least', 'what was asked for' );
    is( $grant{restrict}, 1,       'and the address restriction, which is on unless somebody turned it off' );
    is_deeply( [ sort keys %{ $grant{hypervisors} } ], ['hydra'], 'on the hypervisors it named' );

    my %loose = $recipe->grant( { hypervisor_access => 'full', restrict_key_to_ip => 0 } );
    is( $loose{access},   'full', 'full is carried through' );
    is( $loose{restrict}, 0,      'and an explicit 0 is not overwritten by the default' );
};

subtest 'what comes back off the guest being replaced' => sub {
    my ( undef, $recipe ) = built();

    my %files = $recipe->remote_files( $INSTALL, $DOMAIN );
    is( $files{"$INSTALL/$DOMAIN/etc/trog-provisioner/"}, 'etc/trog-provisioner/', 'the configuration directory, which is where ips.db is' );
    is( $files{"$INSTALL/$DOMAIN/trog-provisioner/"},     'trog-provisioner/',     'and the checkout, if there was one' );

    # Measured on a guest, twice.  bin/new_config fetches these with get_dir,
    # so naming the file rather than the directory is an rsync that fails --
    # and skipping every file in the directory makes the fetch come away empty,
    # which the salvage-gap check refuses to rebuild over.  Either way, every
    # second provision stopped.
    my %skipped = map { $_ => 1 } $recipe->remote_skip();
    ok( !$skipped{'ipmap.cfg'},    'the rendered configuration is not skipped' );
    ok( !$skipped{'recipes.yaml'}, 'nor is the recipe list' );
    ok( $skipped{'secrets.kdbx'},  'but the store is, which is what remote_skip is for' );

    # datadirs makes it before the fragment runs, so the address pool has a
    # directory it can create ips.db in that is not owned by root.
    is_deeply( [ $recipe->datadirs() ], ['etc/trog-provisioner'], 'made ahead of time and owned by the domain' );

    is_deeply( [ $recipe->restores() ], [], 'nothing needs moving afterwards: it all lands where the runner reads it' );
};

subtest 'perl is the whole of what it needs from another recipe' => sub {
    my ( undef, $recipe ) = built();

    my %required = $recipe->required_recipes();
    is_deeply( [ sort keys %required ], ['perl'], 'which is what builds the toolchain koan was missing' );

    # A recipe with no subclass for the distribution in hand inherits an empty
    # deps() and installs nothing at all, which is a failed cpanm forty minutes
    # into a build rather than an apt that said something.
    my %deps = map { $_ => 1 } $recipe->deps();
    ok( $deps{'libvirt-dev'}, 'libvirt-dev, without which Sys::Virt does not build' );
    ok( $deps{'pkg-config'},  'and the thing that finds it' );
    ok( !$deps{xorriso},      'but not xorriso, which is the hypervisor job' );
};

subtest 'the symlink is made with -n, or the second provision fails' => sub {
    my ( undef, $recipe, $vars ) = built();
    my $fragment = $recipe->render(%$vars);

    # Without -n, ln follows the link it made last time and puts the new one
    # inside the directory, which fails as "File exists" on a re-provision and
    # nowhere else.
    like( $fragment, qr{ln -sfn '\Q$INSTALL/$DOMAIN\E/etc/trog-provisioner' /etc/trog-provisioner}, 'pointed at the domain copy' );

    # The domain directory is a home only when the domain names a service user,
    # and this recipe does not require one -- so a dotfile there is read by
    # nobody.  perl.tt was fixed for the same assumption.
    like( $fragment, qr{/etc/profile\.d/trogrunner\.sh}, 'and the shell profile goes somewhere every login shell reads' );
    unlike( $fragment, qr{\Q$INSTALL/$DOMAIN\E/\.bashrc}, 'rather than into a bashrc that may belong to nobody' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
