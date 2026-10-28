#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-trogrunner.t - a guest that can build guests: what it is
handed, what it must never be handed, and what it does with no checkout

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use File::Temp();
use FindBin::libs;
use Provisioner::Utils();
use YAML::XS();

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();
use Trog::Hypervisors();

# These patterns quotemeta a literal on purpose: a fixture string this test
# wrote itself, full of dots and slashes that would otherwise need escaping one
# at a time.  The policy is about production code, where a \Q...\E round
# anything but an interpolated value is usually an accident.
## no critic (RegularExpressions::PreventUselessMetacharacterEscapes)

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
        admin_user  => 'someadmin',
        admin_email => 'someadmin@test.test',
        admin_keys  => ['ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtheadminkey someadmin'],
        gateway     => '192.0.2.254',
        main_ip     => '192.0.2.50',
        %extra,
    );

    $recipe->generate_files( $dir, %vars );
    return ( $dir, $recipe, \%vars );
}

sub slurp { my ( $dir, $file ) = @_; return File::Slurper::read_text("$dir/$file") }

my %HYPERVISORS = (
    hv1 => {
        libvirt_uri => 'qemu+ssh://runner@hv1.test.test:2222/system',
        pool_path   => '/srv/vm-disks/runner',
        pool_name   => 'runner_disks',
        partition   => '/machine/runner',
    },
);

subtest 'what the runner configures its own guests with' => sub {
    my ($dir) = built(
        config => {
            gateway     => '192.0.2.254',
            nameservers => { ns1 => 'ns1.test.test' },
            addresses   => '192.0.2.60-192.0.2.99',
            cidr        => '192.0.2.0/24',
        },
        recipes => { 'g.test.test' => { _global => { aliases => ['www.test.test'] } } },
    );
    my $said   = YAML::XS::Load( slurp( $dir, 'trogrunner.recipes.yaml' ) );
    my $global = $said->{_base}{_global};

    is_deeply( $global->{ip_pool},     { addresses => '192.0.2.60-192.0.2.99', cidr => '192.0.2.0/24' }, 'the pool is one key, with the range it was given' );
    is_deeply( $global->{nameservers}, { ns1       => 'ns1.test.test' },                                 'the nameservers' );
    is_deeply( $said->{'g.test.test'}{_global}{aliases}, ['www.test.test'], 'and a domain of the runner keeps the aliases it was written with' );

    # The runner administers what it builds as whoever administers it, which is
    # what _global already says about this guest -- so nobody has to write it
    # down twice.
    is( $global->{admin_user},  'someadmin',           'the admin comes from the guest own' );
    is( $global->{admin_email}, 'someadmin@test.test', 'and so does the address' );
};

subtest 'a runner told nothing at all can still build a guest' => sub {

    # bin/new_config refuses to generate anything for a domain unless all of
    # these are set, so a default that comes out empty is a runner that cannot
    # do the one thing it exists for.  Measured on a guest: two of them did.
    my ($dir) = built();
    my $global = YAML::XS::Load( slurp( $dir, 'trogrunner.recipes.yaml' ) )->{_base}{_global};

    foreach my $required (qw{basedir admin_user admin_gecos admin_email gateway resolvers}) {
        ok( defined $global->{$required} && $global->{$required} ne q{}, "$required is not empty" )
          or diag 'bin/new_config on the runner would refuse it: the settings of this installation are not valid';
    }

    # The keys are a file of their own, and an empty one is the same failure in
    # different clothes: a runner that builds guests nobody can log in to.
    like( slurp( $dir, 'trogrunner.admin_authorized_keys' ), qr/\Assh-/, 'and the administrator keys came down with it' );
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
                mail  => { names         => { someuser => { password => 'store:mail/someuser/password' } } },
            },
        },
    );

    my $yaml = slurp( $dir, 'trogrunner.recipes.yaml' );
    ok( index( $yaml, 'secret:g.test.test/tls/password' ) >= 0, 'store: comes back out as secret:' )  or diag $yaml;
    ok( index( $yaml, 'secret:mail/someuser/password' ) >= 0,   'however deep it was nested' )        or diag $yaml;
    ok( index( $yaml, 'store:' ) < 0,                           'and nothing is left saying store:' ) or diag $yaml;

    # What the runner gets is a reference, exactly as a hand-written
    # recipes.yaml would hold -- so nothing here is a password even though
    # Trog::Secrets would have resolved one had it been spelled the usual way.
    my $refs = grep { index( $_, 'secret:' ) >= 0 } split( m/\n/, $yaml );
    is( $refs, 2, 'both of them, and nothing else that could be a value' );
};

subtest 'a hypervisor block is written whole, and taken apart for ssh' => sub {
    my ( $dir, $recipe, $vars ) = built( hypervisors => \%HYPERVISORS, hypervisor_access => 'least' );
    my $conf = slurp( $dir, 'trogrunner.hypervisors.conf' );

    like( $conf, qr/^\[hv1\]$/m,                                 'one block per hypervisor' );
    like( $conf, qr/^pool_path\s+=[ ]\/srv\/vm-disks\/runner$/m, 'the pool it is confined to' );
    like( $conf, qr/^pool_name\s+=[ ]runner_disks$/m,            'named as well as pathed, or libvirt ignores the path' );
    like( $conf, qr/^partition\s+=[ ]\/machine\/runner$/m,       'and the slice its guests land in' );

    # Read back as the runner reads it, so the key is one the runner takes.
    my ($budgeted) = built( hypervisors => { hv1 => { %{ $HYPERVISORS{hv1} }, max_memory => 131_072 } }, hypervisor_access => 'least' );
    my $runner_hv = Trog::Hypervisors->load("$budgeted/trogrunner.hypervisors.conf")->hypervisor('hv1');
    is( $runner_hv->max_memory, 131_072, 'the memory budget of the partition reaches the hypervisor of the runner' );

    # Not for the fleet file -- for ssh-keyscan.  libvirt's qemu+ssh transport
    # verifies host keys where Net::OpenSSH::More does not, so an unseeded
    # known_hosts is a hypervisor that refuses on first contact while a plain
    # ssh to the same machine works.
    my %got = $recipe->validate(%$vars);
    is( $got{hypervisors}{hv1}{ssh_host}, 'hv1.test.test', 'the host out of the URI' );
    is( $got{hypervisors}{hv1}{ssh_user}, 'runner',        'the user' );
    is( $got{hypervisors}{hv1}{ssh_port}, 2222,            'and the port, when it is not 22' );

    my $fragment = $recipe->render(%$vars);
    like( $fragment, qr/ssh-keyscan[ ]-p[ ]'2222'[ ]'hv1\.test\.test'/, 'which is what gets scanned' );

    # Into the home ssh will read, asked of passwd, rather than into the domain
    # directory -- which is a home only when the domain names a service user.
    like( $fragment, qr/getent[ ]passwd[ ]'someadmin'/, 'the home is asked for rather than assumed' );
    like( $fragment, qr{known_hosts},                   'and that is where the host keys go' );
};

subtest 'a hypervisor we could not get a shell on is refused here, not on the guest' => sub {

    # Trog::HV's rule: a remote hypervisor whose transport gives no shell is
    # half usable, and the missing half is not optional.  Better said while
    # somebody is reading the output than an hour into a build.
    like(
        exception {
            built( hypervisors => { far => { libvirt_uri => 'qemu+tcp://far.test.test/system' } } );
        },
        qr/needs[ ]an[ ]ssh[ ]transport/,
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

# What it hands the perl recipe, as that recipe's target will install it: each
# cpan_install, as the words it is handed.
sub cpan_steps {
    my ( $recipe, $vars ) = @_;

    my %required = $recipe->required_recipes(%$vars);
    my %handed   = $required{perl}->(%$vars);
    my $perl     = Provisioner::Cookbook->load( 'perl', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );

    # Only what perl declares, out of the runner's configuration: bin/new_config
    # hands each recipe its own stanza and the settings it declares, never
    # another recipe's fields.
    my @lines = grep { m{/cpan_install\b} } split( m/\n/, $perl->render( $perl->takes(%$vars), %handed ) );
    return map { [m/'([^']*)'/g] } @lines;
}

subtest 'Sys::Virt is pinned, and pinned before anything resolves dependencies' => sub {
    my ( undef, $recipe, $vars ) = built( libvirt_version => '10.0.0' );
    my @steps = cpan_steps( $recipe, $vars );

    # The ordering is the whole point.  Left to a dependency list cpanm takes
    # the newest Sys::Virt, whose Makefile.PL wants a libvirt-dev far newer than
    # a noble guest has -- and says so forty minutes in, in a message about
    # pkg-config rather than about ordering.
    is_deeply( [ @{ $steps[0] }[ -2, -1 ] ], [ 'install', 'Sys::Virt@10.0.0' ], 'pinned to what was asked for, and first' );

    # authordeps before listdeps is cpan_install's to keep, inside the one step.
    my ($dzil) = grep { $steps[$_][-2] eq 'dzil' } 0 .. $#steps;
    ok( defined $dzil && $dzil > 0, 'ahead of the checkout dependencies' );
    is( $steps[$dzil][-1], "$INSTALL/$DOMAIN/trog-provisioner", 'which are the checkout it made' );
};

subtest 'an unnamed libvirt version is asked of the guest rather than guessed' => sub {
    my ( undef, $recipe, $vars ) = built();
    my @steps = cpan_steps( $recipe, $vars );

    # A recipe cannot load Trog::HV to ask a hypervisor, so a written-down
    # default would be a guess that goes stale.  The guest answers for itself,
    # when the step runs.
    is_deeply( [ @{ $steps[0] }[ -3 .. -1 ] ], [qw{pin libvirt Sys::Virt}], 'at whatever pkg-config says the guest libvirt is' );
};

subtest 'Dist::Zilla is not asked for: the perl comes with it' => sub {
    my ( undef, $recipe, $vars ) = built();

    # build_latest_perl.sh installs it alongside cpanm, since a distribution
    # that needs dzil to say what it needs cannot install dzil for itself.
    is_deeply( [ grep { $_->[-1] eq 'Dist::Zilla' } cpan_steps( $recipe, $vars ) ], [], 'nothing here installs it' );
};

subtest 'the checkout is optional, which is the case koan needs' => sub {
    my ( undef, $with, $wvars ) = built();
    like( $with->render(%$wvars), qr{git[ ]clone[ ]--branch[ ]'master'}, 'cloned by default' );

    my ( undef, $without, $ovars ) = built( checkout => 0, deps_from => ['/srv/code/trog-provisioner'] );
    my $fragment = $without->render(%$ovars);

    unlike( $fragment, qr/git[ ]clone/, 'and not at all when the runner manages its own' );
    ok( ( grep { $_->[-2] eq 'dzil'                  && $_->[-1] eq '/srv/code/trog-provisioner' } cpan_steps( $without, $ovars ) ), 'deps come from where it says instead' );
    ok( !( grep { $_->[-1] =~ m{/trog-provisioner\z} && $_->[-1] ne '/srv/code/trog-provisioner' } cpan_steps( $without, $ovars ) ), 'and not from a checkout that was never made' );
};

subtest 'the checkout cannot be the domain directory' => sub {

    # service_user makes that directory before the fragment runs, and git clone
    # refuses a target that is not empty -- so this would fail on the guest,
    # after the packages, in a way that reads as a git problem.
    like(
        exception { built( checkout_dir => '.' ) },
        qr/will[ ]not[ ]drop[ ]a[ ]repo[ ]into[ ]the[ ]domain[ ]directory/,    ## no critic (RegularExpressions::ProhibitComplexRegexes)
        'refused while somebody is still reading the output'
    );
};

subtest 'a path meant to be under the domain directory has to be' => sub {

    # `store: /etc/trog-provisioner/secrets.kdbx` is the obvious thing to write
    # and means something else: it renders under the domain directory anyway,
    # as //etc/..., and fails as a missing file rather than as a mistake.
    like( exception { built( store        => '/etc/trog-provisioner/secrets.kdbx' ) }, qr/cannot[ ]start[ ]with[ ]a[ ]slash/, 'an absolute store is refused' );
    like( exception { built( store        => '../../etc/secrets.kdbx' ) },             qr/climbs[ ]out[ ]of[ ]it/,            'and so is one that climbs out' );
    like( exception { built( checkout_dir => '/srv/code' ) },                          qr/cannot[ ]start[ ]with[ ]a[ ]slash/, 'the same for the checkout' );

    # Only when there is a checkout to put anywhere.  A runner that manages its
    # own repositories never uses the field.
    my ( undef, $recipe, $vars ) = built( checkout => 0, checkout_dir => '/srv/code' );
    ok( $recipe->render(%$vars), 'and not checked at all when nothing is being cloned' );
};

subtest 'the key it generates is one both readers of these agree on' => sub {
    my ( undef, $recipe ) = built();
    my %secrets = $recipe->guest_secrets( $INSTALL, $DOMAIN );
    my ($path) = keys %secrets;

    my $key = $secrets{$path}{generate}->();
    like( $key, qr/\A-----BEGIN[ ]OPENSSH[ ]PRIVATE[ ]KEY-----\n/, 'an OpenSSH private key' );

    # Net::SSH::Perl::Key writes the whole payload on one line.  OpenSSH reads
    # that; CryptX -- which is what Provisioner::Utils uses to derive the public
    # half out of the store later -- refuses it as "Invalid input packet", and
    # RFC 7468 puts the limit at 64, so the strict reader is the correct one.
    my @body = grep { !m/^-----/ } split( m/\n/, $key );
    ok( ( scalar @body > 1 ), 'wrapped rather than written as one line' );
    is( scalar( grep { length($_) > 64 } @body ), 0, 'at no more than 64 columns, which is what RFC 7468 asks' );

    # The assertion that would have caught it: the key has to survive the round
    # trip through the store and back out as a public half.
    my $tmp = File::Temp->new( UNLINK => 1 );
    print {$tmp} "$key\n";
    $tmp->flush();
    chmod 0600, $tmp->filename;

    my $pub = eval { Provisioner::Utils::ssh_pubkey_from_private( $tmp->filename ) };
    like( $pub // "died: $@", qr/\Assh-ed25519[ ]/, 'and bin/provision can derive its public half' );
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
    is_deeply( { $recipe->grant( {} ) },                                                            {}, 'nothing, by default' );
    is_deeply( { $recipe->grant(undef) },                                                           {}, 'and nothing for a domain that does not run the recipe at all' );
    is_deeply( { $recipe->grant( { hypervisor_access => 'none', hypervisors => \%HYPERVISORS } ) }, {}, 'nor when it is switched off with hypervisors named' );

    my %grant = $recipe->grant( { hypervisor_access => 'least', hypervisors => \%HYPERVISORS } );
    is( $grant{access},   'least', 'what was asked for' );
    is( $grant{restrict}, 1,       'and the address restriction, which is on unless somebody turned it off' );
    is_deeply( [ sort keys %{ $grant{hypervisors} } ], ['hv1'], 'on the hypervisors it named' );

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
    ok( !$skipped{'recipes.yaml'}, 'the rendered configuration is not skipped' );
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
    like( $fragment, qr{ln[ ]-sfn[ ]'\Q$INSTALL/$DOMAIN\E/etc/trog-provisioner'[ ]/etc/trog-provisioner}, 'pointed at the domain copy' );    ## no critic (RegularExpressions::ProhibitComplexRegexes)

    # The domain directory is a home only when the domain names a service user,
    # and this recipe does not require one -- so a dotfile there is read by
    # nobody.  perl.tt was fixed for the same assumption.
    like( $fragment, qr{/etc/profile\.d/trogrunner\.sh}, 'and the shell profile goes somewhere every login shell reads' );
};

# --- What a runner needs on its hypervisors -----------------------------------
#
# The steps run on machines that a test cannot have, so each machine is a fake
# that records what it was asked.  Trog::Steps, which hands the steps their
# machines, has a test of its own.

{

    package Test::FakeLogin;    # a hypervisor as the user of a libvirt URI

    sub new ( $class, %files ) { return bless { files => {%files}, appended => [] }, $class }
    sub ssh_user ($)           { return 'runner' }
    sub describe ($)           { return 'the fake' }
    sub authorized_keys ($)    { return '/bogus/home/runner/.ssh/authorized_keys' }
    sub file_exists ( $self, $path )        { return exists $self->{files}{$path} }
    sub read_text   ( $self, $path )        { return $self->{files}{$path} }
    sub write_text  ( $self, $path, $text ) { $self->{files}{$path} = $text; return 1 }

    sub append_line ( $self, $path, $line ) {
        push @{ $self->{appended} }, $line;
        $self->{files}{$path} .= "$line\n";
        return 1;
    }

    package Test::FakeAdmin;    # a hypervisor as the account of hypervisors.conf

    sub new ($class) { return bless { asked => [] }, $class }

    sub runner_account_plan      ( $self, %args )            { push @{ $self->{asked} }, [ plan => \%args ];            return {%args} }
    sub runner_account_steps     ( $self, $plan )            { push @{ $self->{asked} }, [ account => $plan ];          return { what => 'make it' } }
    sub runner_removal_steps     ( $self, $plan )            { push @{ $self->{asked} }, [ remove => $plan ];           return { what => 'unmake it' } }
    sub runner_key_steps         ( $self, $user, $line )     { push @{ $self->{asked} }, [ key => $user, $line ];       return { what => 'let it in' } }
    sub runner_key_removal_steps ( $self, $user, $material ) { push @{ $self->{asked} }, [ unkey => $user, $material ]; return { what => 'shut it out' } }
}

# The store as bin/provision hands it to a step: by reference.  The recipe's own
# generator, rather than a key made some other way here.  A made-up string would
# only prove that CryptX rejects made-up strings, and a key from ssh-keygen would
# not exercise the thing that actually goes in the store, which has a rewrap in
# it because the two do not agree by default.
sub runner_secrets {
    my ( undef, $recipe ) = built();
    my ($entry) = values %{ { $recipe->guest_secrets( $INSTALL, $DOMAIN ) } };
    return { $entry->{ref} => $entry->{generate}->() };
}

subtest 'a runner is let in to each hypervisor that it names, as the user of its URI' => sub {
    my $dir   = tempdir( CLEANUP => 1 );
    my $class = Provisioner::Cookbook->load('trogrunner');

    my %two   = ( %HYPERVISORS, hv2 => { libvirt_uri => 'qemu+ssh://runner@hv2.test.test/system' } );
    my @steps = $class->outside_steps( $DOMAIN, hypervisor_access => 'least', restrict_key_to_ip => 0, hypervisors => \%two );
    is_deeply( [ map { $_->{machine} } @steps ], [ map { { uri => $two{$_}{libvirt_uri} } } qw{hv1 hv2} ], 'one step for each hypervisor, on its URI' );
    is_deeply( [ map { $_->{when} } @steps ],    [qw{secrets secrets}],                                    'once the key is out of the store, before the makefile starts' );

    my %context = ( domain => $DOMAIN, domain_dir => $dir, dryrun => 0, secrets => runner_secrets() );
    my $login   = Test::FakeLogin->new();
    my @actions = $steps[0]{apply}->( $login, %context );
    ok( !$actions[0]{done}->(), 'a hypervisor without the key does not have it yet' );
    $actions[0]{do}->();

    my ($line) = @{ $login->{appended} };
    like( $line, qr/\Assh-ed25519[ ]/,                               'the public half, derived rather than stored' );
    like( $line, qr/\Qtrog-provisioner runner runner.test.test\E\z/, 'and it says whose it is' );
    ok( $actions[0]{done}->(), 'and a second provision finds it there' );

    # bin/destroy reads this rather than the store, so that taking the access
    # away never stops to ask for a passphrase.
    chomp( my $written = File::Slurper::read_text("$dir/hypervisor-key.pub") );
    is( $written, $line, 'and it is written beside the domain for the revert' );

    my @undo = $steps[0]{revert}->( $login, domain => $DOMAIN, domain_dir => $dir, secrets => {} );
    $undo[0]{do}->();
    is( $login->{files}{ $login->authorized_keys }, q{}, 'the revert takes it away again, from the public half alone' );
};

subtest 'the key is held to the address of the runner' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    my $held = '192.0.2.77';
    $pool->redefine( held_by => sub { return $held } );

    # Fresh steps for each run, as Trog::Steps asks for them: the steps of one
    # run work the line out once.
    my $step    = sub { ( Provisioner::Cookbook->load('trogrunner')->outside_steps( $DOMAIN, hypervisor_access => 'least', hypervisors => \%HYPERVISORS ) )[0] };
    my $login   = Test::FakeLogin->new();
    my %context = ( domain => $DOMAIN, domain_dir => $dir, dryrun => 0, secrets => runner_secrets() );
    ( $step->()->{apply}->( $login, %context ) )[0]{do}->();
    like( $login->{appended}[0], qr/\Afrom="192[.]0[.]2[.]77"[ ]ssh-ed25519[ ]/, 'with from= and the address that it holds in the pool' );

    # A runner that takes a lease has no address that stays.
    $held = undef;
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    $login = Test::FakeLogin->new();
    ( $step->()->{apply}->( $login, %context ) )[0]{do}->();
    like( $login->{appended}[0], qr/\Assh-ed25519[ ]/,                            'without an address, the key goes in unrestricted' );
    like( "@warned",             qr/holds[ ]no[ ]address[ ]in[ ]the[ ]ip[ ]pool/, 'and it says so' );
};

subtest 'a dry run has no store, and says what it would let in' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my $steps    = sub { ( Provisioner::Cookbook->load('trogrunner')->outside_steps( $DOMAIN, hypervisor_access => 'least', restrict_key_to_ip => 0, hypervisors => \%HYPERVISORS ) )[0] };
    my $step     = $steps->();
    my %context  = ( domain => $DOMAIN, domain_dir => $dir, dryrun => 1, secrets => {} );
    my ($action) = $step->{apply}->( Test::FakeLogin->new(), %context );
    like( $action->{what}, qr/a[ ]dry[ ]run[ ]does[ ]not[ ]open/, 'a first provision has no public half yet, and says why' );

    File::Slurper::Temp::write_text( "$dir/hypervisor-key.pub", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusBogusBogusBogusBogusBogusBogus x\n" );
    my $login = Test::FakeLogin->new( '/bogus/home/runner/.ssh/authorized_keys' => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusBogusBogusBogusBogusBogusBogus x\n" );
    ($action) = $steps->()->{apply}->( $login, %context );
    ok( $action->{done}->(), 'a later one asks the hypervisor about the key that the last provision left' );

    like( exception { $steps->()->{apply}->( $login, %context, dryrun => 0 ) }, qr/the[ ]store[ ]had[ ]no[ ]key/, 'and a real provision without the key from the store stops' );
};

subtest 'a runner with an account has it made, and its key put in as root' => sub {
    my $dir     = tempdir( CLEANUP => 1 );
    my %blocks  = ( hv1 => { %{ $HYPERVISORS{hv1} }, account => { quota => '500G', cores => 32 } } );
    my @steps   = Provisioner::Cookbook->load('trogrunner')->outside_steps( $DOMAIN, hypervisor_access => 'least', restrict_key_to_ip => 0, hypervisors => \%blocks );
    my %context = ( domain => $DOMAIN, domain_dir => $dir, dryrun => 0, secrets => runner_secrets() );

    is_deeply( [ map { $_->{id} } @steps ],      [qw{trogrunner:account:hv1 trogrunner:key:hv1}],      'the account, and then the key' );
    is_deeply( [ map { $_->{machine} } @steps ], [ { hypervisor => 'hv1' }, { hypervisor => 'hv1' } ], 'both as the account of the block of that name in hypervisors.conf, and not as the runner' );

    my $admin = Test::FakeAdmin->new();
    $_->{apply}->( $admin, %context ) for @steps;
    my ( $plan, $account, $key ) = @{ $admin->{asked} };
    is_deeply(
        $plan->[1],
        { user => 'runner', pool_name => 'runner_disks', pool_path => '/srv/vm-disks/runner', partition => '/machine/runner', quota => '500G', cores => 32 },
        'the plan is the user of the URI, the pool and the slice of the entry, and the limits of the account'
    );
    is( $account->[0], 'account', 'and the account is made from it' );
    is( $key->[1],     'runner',  'and the key goes to that user' );
    my ( $type, undef, $comment ) = split q{ }, $key->[2], 3;
    is( "$type $comment", "ssh-ed25519 trog-provisioner runner $DOMAIN", 'and it is the key of the runner' );

    $admin = Test::FakeAdmin->new();
    $_->{revert}->( $admin, %context, secrets => {} ) for reverse @steps;
    is_deeply( [ map { $_->[0] } @{ $admin->{asked} } ], [qw{unkey plan remove}], 'the revert takes the key away, and then the account' );
};

subtest 'access taken away leaves only what to take back' => sub {
    my @steps = Provisioner::Cookbook->load('trogrunner')->outside_steps( $DOMAIN, hypervisors => \%HYPERVISORS );
    is( scalar @steps, 1, 'the hypervisor that a provision may have let the runner in to' );
    ok( !$steps[0]{apply} && $steps[0]{revert}, 'with a revert, and nothing to apply' );

    is_deeply( [ Provisioner::Cookbook->load('trogrunner')->outside_steps( $DOMAIN, hypervisor_access => 'least' ) ], [], 'and nothing at all for a runner that names no hypervisor' );
};

subtest 'an account that cannot be made is refused when the configuration is written' => sub {
    my %entry = %{ $HYPERVISORS{hv1} };
    my $with  = sub (%changed) { return ( hypervisor_access => 'least', hypervisors => { hv1 => { %entry, account => { quota => '1T' }, %changed } } ) };

    like( exception { built( $with->(), hypervisor_access => 'none' ) }, qr/hypervisor_access[ ]is[ ]none/, 'an account with no access to make it' );
    like( exception { built( $with->( pool_name   => q{} ) ) },                               qr/needs[ ]pool_name[ ]and[ ]pool_path/, 'an account with no pool to hold its quota' );
    like( exception { built( $with->( libvirt_uri => 'qemu+ssh://hv1.test.test/system' ) ) }, qr/names[ ]no[ ]user/,                   'an account for nobody' );
    like( exception { built( $with->( account     => {} ) ) },                                qr/not[ ]valid/,                         'and an account with no quota' );
    like( exception { built( $with->( account     => { quota => '1T', cores => 0 } ) ) },     qr/not[ ]valid/,                         'an account with no CPU at all' );
    like( exception { built( $with->( account     => { quota => '1T', cores => 0.5 } ) ) },   qr/not[ ]valid/,                         'an account with a part of a core' );

    my %unpartitioned = %entry;
    delete $unpartitioned{partition};
    like( exception { built( hypervisors => { hv1 => { %unpartitioned, max_memory => 4096 } } ) }, qr/partition/, 'a memory budget with no partition to be the budget of' );

    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    built( hypervisor_access => 'least' );
    like( "@warned", qr/no[ ]hypervisor[ ]is[ ]named/, 'access with no hypervisor to give it gets a warning' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
