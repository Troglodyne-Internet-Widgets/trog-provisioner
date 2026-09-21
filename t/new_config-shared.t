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

my $HOST   = 'host.test.test';
my $TENANT = 'tenant.test.test';

# A guest with two domains on it, generated the way bin/provision generates one:
# naming the tenant expands the list to include its host, and the host is done
# first.
sub generate {
    my (%on) = @_;
    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/domains";

    # Where each domain's data comes from.  The generator refuses a domain that
    # cannot say, so the directory has to be there as well as named below.
    mkdir "$tmpdir/data";
    mkdir "$tmpdir/data/$_" for ( $HOST, $TENANT );

    my $pool = join( ' ', map { "192.0.2.$_" } 100 .. 199 );

    # One resolver on purpose, written as a scalar rather than a list.  That is
    # what an operator writes, and bin/new_config dereferenced it raw when it
    # wrote provision.conf -- so generating from this is what catches it coming
    # back.
    my %global = (
        data_source    => "$tmpdir/data",
        basedir        => "$tmpdir/domains",
        transfer_user  => 'someadmin',
        admin_user     => 'someadmin',
        admin_email    => 'bogus@test.test',
        admin_gecos    => 'Test Test',
        gateway        => '192.0.2.254',
        resolvers      => '192.0.2.254',
        bridge_devname => 'ens4',
        dhcp_devname   => 'ens3',
        ip_pool        => { addresses => $pool },
        nameservers    => { ns1       => 'ns1.test.test', ns2 => 'ns2.test.test' },
    );

    my %recipes = (

        _base   => { _global => \%global },
        _shared => { $HOST   => [$TENANT] },
        $HOST   => $on{host}   // { nosnap => undef },
        $TENANT => $on{tenant} // { nosnap => undef },
    );

    my ( $rh, $recipe_file ) = tempfile();
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
    like( $err, qr{/listeners/3000:.*\(nosnap,[ ]tmpfs\)}, 'at the port, naming both recipes' );
    ok( !-f "$domains/$TENANT/Makefile", 'and nothing is generated for the domain that came second' );

    ( $err, $domains ) = generate();
    is( $err, undef, 'one recipe on two domains is one claim' ) or diag $err;

    $mock{tmpfs}->redefine( listens => sub { return 3001 } );
    ( $err, $domains ) = generate( host => { nosnap => undef }, tenant => { tmpfs => undef } );
    is( $err, undef, 'and two recipes on two ports are two claims' ) or diag $err;
};

done_testing;
