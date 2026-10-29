#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/new_config-shared.t - what bin/new_config refuses when one domain is layered
onto another

=cut

# Asserting a file was generated is what this file does, and -f is how you ask.
## no critic (ValuesAndExpressions::ProhibitFiletest_f)

use FindBin;
use FindBin::libs;

# Never the installation's real configuration: what this asserts should not
# depend on which machine it runs on, and the pool it takes an address out of
# has to be one of ours.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempdir tempfile};
use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();

use Provisioner::Cookbook();

# The administrator's keys are read out of the configuration directory now,
# rather than named as an identity for cloud-init to fetch at first boot.
File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAadminskey someadmin\n" );

# Loaded here so Test::MockModule has a package to attach to: the generator
# requires a recipe only when it reaches it, which is after the mock is wanted.
Provisioner::Cookbook->load('nosnap');

require Trog::HV;
require Trog::HV::Libvirt;

# The two facts the generator asks a hypervisor for.  Answered here because what
# this file is about is what the generator refuses, and asking a real one would
# mean it only runs on a machine that happens to be one.
my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
$hv_mock->redefine( virbr_ip  => sub { '192.168.122.1' } );
$hv_mock->redefine( sshd_port => sub { 22 } );

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

# The resolvers, the gateway and the pool that the block of the hypervisor
# names, which the local hypervisor of a test has no block for.  See
# Trog::HV/configured_resolvers and Trog::HV/guest_pool.
my $hv_network = Test::MockModule->new('Trog::HV');
$hv_network->redefine( configured_resolvers => sub { return ('192.0.2.254') } );
$hv_network->redefine( configured_gateway   => sub { return '192.0.2.254' } );
$hv_network->redefine(
    guest_pool => sub {
        return { addresses => [ map { "192.0.2.$_" } 100 .. 199 ] };
    }
);

my $HOST   = 'host.test.test';
my $TENANT = 'tenant.test.test';

# A guest with two domains on it, generated the way bin/provision generates one:
# naming the tenant expands the list to include its host, and the host is done
# first.
sub generate {
    my (%on) = @_;
    my $tmpdir = $on{tmpdir} // tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/domains";

    # Where each domain's data comes from.  The generator refuses a domain that
    # cannot say, so the directory has to be there as well as named below.
    mkdir "$tmpdir/data";
    mkdir "$tmpdir/data/$_" for ( $HOST, $TENANT );

    # One resolver on purpose, written as a scalar rather than a list.  That is
    # what an operator writes, and bin/new_config dereferenced it raw when it
    # wrote provision.conf -- so generating from this is what catches it coming
    # back.
    my %global = (
        data_source   => "$tmpdir/data",
        basedir       => "$tmpdir/domains",
        transfer_user => 'someadmin',
        admin_user    => 'someadmin',
        admin_email   => 'bogus@test.test',
        admin_gecos   => 'Test Test',
        nameservers   => { ns1 => 'ns1.test.test', ns2 => 'ns2.test.test' },
    );

    my %recipes = (

        _base   => { _global => \%global },
        _shared => { $HOST   => [$TENANT] },
        $HOST   => $on{host}   // { nosnap => undef },
        $TENANT => $on{tenant} // { nosnap => undef },
    );

    my ( $rh, $recipe_file ) = tempfile( UNLINK => 1 );
    print {$rh} YAML::XS::Dump( \%recipes );
    close($rh) or die "Could not close $recipe_file: $!";

    # Nothing to reset between runs: each one generates the host again, which
    # replaces what it recorded last time.

    my $err = exception {
        Trog::Provisioner::Config::Generator::main(
            '--recipes', $recipe_file,
            '--skip_ssh',
            $TENANT,
        );
    };

    return ( $err, "$tmpdir/domains" );
}

# Every file in t/ goes to the guest and runs there, so a test left over from a
# recipe taken off the domain fails the build on a guest that has no such thing.
subtest 'a generation replaces the guest tests of the last one' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    my ( $err, $domains ) = generate( tmpdir => $tmpdir );
    is( $err, undef, 'the first generation runs' ) or diag $err;

    my $stale = "$domains/$HOST/t/gone.t";
    File::Slurper::Temp::write_text( $stale, "print qq{not ok 1\\n};\n" );
    ( $err, $domains ) = generate( tmpdir => $tmpdir );
    is( $err, undef, 'and the second' ) or diag $err;

    ok( !-e $stale,                     'the test of a recipe no longer on the domain is gone' );
    ok( -f "$domains/$HOST/t/nosnap.t", 'and the test of one still on it is there' );
};

subtest 'two domains on one guest generate when the recipe can be shared' => sub {
    my ( $err, $domains ) = generate();

    is( $err, undef, 'the generation runs to the end' ) or diag $err;
    ok( -f "$domains/$HOST/Makefile",   'the host was generated' );
    ok( -f "$domains/$TENANT/Makefile", 'and so was the domain layered onto it' );

    # Neither of these guests has the data recipe in its build: it is required
    # by a recipe that declares restores, and nosnap declares none.  The target
    # is makefile.tt's own and is emitted regardless, so what it interpolates
    # there is an empty fragment rather than an absent one.
    like(
        File::Slurper::read_text("$domains/$HOST/Makefile"),
        qr{^/etc/provisioner/state/\Q$HOST\E/data:$}m,
        'the data target is written even with no data recipe to fill it'
    );
};

# The guest of the host fetches the payload of the tenant with the key of the
# host, so the modules of both are in the one file that the key reaches.
subtest 'the key of the host reaches the modules of its tenant, and the tenant has no file of its own' => sub {
    my ( $err, $domains ) = generate();
    is( $err, undef, 'the generation runs to the end' ) or diag $err;

    my $has = sub ( $file, $text, $name ) { cmp_ok( index( File::Slurper::read_text($file), $text ), '>=', 0, $name ) or diag File::Slurper::read_text($file) };
    $has->( "$domains/$HOST/rsyncd.conf",           "\n&include $domains/$HOST/rsyncd.d\n",         'the file of the host includes the part of each domain on its guest' );
    $has->( "$domains/$HOST/rsyncd.d/$HOST.conf",   "[payload.$HOST]\npath = $domains/$HOST\n",     'its own part serves its payload' );
    $has->( "$domains/$HOST/rsyncd.d/$TENANT.conf", "[payload.$TENANT]\npath = $domains/$TENANT\n", 'and the part of the tenant, beside it, serves the payload of the tenant' );
    ok( !-e "$domains/$TENANT/rsyncd.conf", 'the tenant gets no file of its own, because no key of its own fetches anything' );
};

# The fragment of a recipe fetches its module by name, so two modules of one
# name would serve one of the two directories to both.
subtest 'a recipe that serves a directory under a name that is taken is refused' => sub {
    my $nosnap = Test::MockModule->new('Provisioner::Recipe::nosnap');

    $nosnap->redefine( fetch_sources => sub { return ( data => '/bogus/elsewhere' ) } );
    my ($err) = generate();
    like( $err // q{}, qr{nosnap[ ]serves[ ]/bogus/elsewhere},       'the name of the data of every guest' );
    like( $err // q{}, qr{module[ ]data,[ ]which[ ]is[ ]the[ ]name}, 'which the message names' );

    $nosnap->redefine( fetch_sources => sub { return ( skel => '/bogus/elsewhere' ) } );
    ($err) = generate( host => { nosnap => undef, adminconfig => { skel => '/bogus/dotfiles' } } );
    like( $err // q{}, qr{already[ ]serves[ ]/bogus/}, 'and a name that another recipe of the domain serves' );
};

# A tenant runs on the guest of its host, so the release of the tenant is the
# release of that guest.
subtest 'a tenant on another release than its host is refused' => sub {
    my ( $err, $domains ) = generate( tenant => { _global => { release => 'resolute' }, nosnap => undef } );

    ok( $err, 'the generation stops' ) or return;
    like( $err, qr/names[ ]the[ ]release[ ]resolute/, 'naming the release of the tenant' );
    like( $err, qr/\Q$HOST\E[ ]is[ ]on[ ]noble/,      'and the host and its release' );
    ok( !-f "$domains/$TENANT/Makefile", 'and nothing is generated for it' );
};

subtest 'a host and its tenant on one release that is not the pinned one' => sub {
    my %resolute = ( _global => { release => 'resolute' }, nosnap => undef );
    my ( $err, $domains ) = generate( host => {%resolute}, tenant => {%resolute} );

    is( $err, undef, 'the generation runs to the end' ) or return diag $err;

    my $conf = File::Slurper::read_text("$domains/$TENANT/provision.conf");
    like( $conf, qr/^\s*release=resolute$/m,                                       'provision.conf names the release of the domain' );
    like( $conf, qr{^\s*image=https://cloud-images[.]ubuntu[.]com/resolute/\S+$}m, 'and the hypervisor image of that release' );
};

subtest 'a recipe that cannot be shared is refused rather than replacing the first domain' => sub {

    # One of these on a guest, and it cannot be told about a second domain: the
    # second provision would not add itself, it would replace what the first
    # configured, and say nothing about it.
    my $nosnap = Test::MockModule->new('Provisioner::Recipe::nosnap');
    $nosnap->redefine( is_multi_tenant => sub { 0 } );

    my ( $err, $domains ) = generate();

    ok( $err, 'the generation stops' ) or return;
    like( $err, qr/\bnosnap\b/,  'naming the recipe that cannot take a second domain' );
    like( $err, qr/\Q$TENANT\E/, 'and the domain being layered on' );
    like( $err, qr/\Q$HOST\E/,   'and the one it is being layered onto' );

    ok( !-f "$domains/$TENANT/Makefile", 'and nothing is generated for it' );
};

subtest 'two recipes on one guest cannot claim one port, from two domains either' => sub {

    # Two recipes that need nothing, made to bind a port.  A domain resolves its
    # recipes alone, so only the guest's claims so far can show ufw the other.
    Provisioner::Cookbook->load($_) for qw{tmpfs};
    my %mock = map { $_ => Test::MockModule->new("Provisioner::Recipe::$_") } qw{nosnap tmpfs};
    $mock{$_}->redefine( listens => sub { return 3000 } ) for keys %mock;

    my ( $err, $domains ) = generate( host => { nosnap => undef }, tenant => { tmpfs => undef } );
    ok( $err, 'the generation stops' ) or return;
    like( $err, qr{/listeners/3000/:::.*\(nosnap,[ ]tmpfs\)}, 'at the port and the address, naming both recipes' );
    ok( !-f "$domains/$TENANT/Makefile", 'and nothing is generated for the domain that came second' );

    ( $err, $domains ) = generate();
    is( $err, undef, 'one recipe on two domains is one claim' ) or diag $err;

    $mock{tmpfs}->redefine( listens => sub { return 3001 } );
    ( $err, $domains ) = generate( host => { nosnap => undef }, tenant => { tmpfs => undef } );
    is( $err, undef, 'and two recipes on two ports are two claims' ) or diag $err;

    # The kernel lets loopback and a specific external address share a port.
    $mock{nosnap}->redefine( listens => sub { return '127.0.0.1:3000' } );
    $mock{tmpfs}->redefine( listens => sub { return '203.0.113.8:3000' } );
    ( $err, $domains ) = generate( host => { nosnap => undef }, tenant => { tmpfs => undef } );
    is( $err, undef, 'two recipes on two addresses of one port are two claims' ) or diag $err;

    # It does not let every address share a port with anything.
    $mock{tmpfs}->redefine( listens => sub { return 3000 } );
    ( $err, $domains ) = generate( host => { nosnap => undef }, tenant => { tmpfs => undef } );
    ok( $err, 'and a tenant on every address of a port that the host binds on loopback is refused' ) or return;
    like( $err, qr{/listeners/3000:}, 'at the port' );
    my $named = quotemeta q{(127.0.0.1 {nosnap}, :: {tmpfs})};
    like( $err, qr{$named}, 'naming each address and the recipe on it' );
};

subtest 'two recipes that cannot share a machine are refused on a host and its tenant' => sub {
    Provisioner::Cookbook->load($_) for qw{tmpfs};
    my $tmpfs = Test::MockModule->new('Provisioner::Recipe::tmpfs');
    $tmpfs->redefine( exclusive_on_machine_with => sub { return qw{nosnap} } );

    my ( $err, $domains ) = generate( host => { nosnap => undef }, tenant => { tmpfs => undef } );
    ok( $err, 'the generation stops when the tenant names the recipe of the host' ) or return;
    my $refused = qr/[ ]has[ ]tmpfs,[ ]which[ ]cannot[ ]be[ ]on[ ]one[ ]machine/;
    my $holder  = qr/[ ]with[ ]the[ ]nosnap[ ]of[ ]/;
    like( $err, qr/\Q$TENANT\E$refused$holder\Q$HOST\E/, 'naming both recipes and both domains' );
    ok( !-f "$domains/$TENANT/Makefile", 'and nothing is generated for the tenant' );

    $tmpfs->unmock('exclusive_on_machine_with');
    my $nosnap = Test::MockModule->new('Provisioner::Recipe::nosnap');
    $nosnap->redefine( exclusive_on_machine_with => sub { return qw{tmpfs} } );
    ( $err, $domains ) = generate( host => { nosnap => undef }, tenant => { tmpfs => undef } );
    like( $err // q{}, qr/cannot[ ]be[ ]on[ ]one[ ]machine/, 'and when the host names the recipe of the tenant' );

    $nosnap->unmock('exclusive_on_machine_with');
    ( $err, $domains ) = generate( host => { nosnap => undef }, tenant => { tmpfs => undef } );
    is( $err, undef, 'and when neither names the other, both generate' ) or diag $err;
};

done_testing;
