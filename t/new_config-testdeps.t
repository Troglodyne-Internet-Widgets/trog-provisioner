#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/new_config-testdeps.t - which release the makefile's testdeps line asks cpanm
for, decided the way scripts/cpan_install decides it

=cut

use FindBin;
use FindBin::libs;

# Never the installation's real configuration: what this asserts should not
# depend on which machine it runs on.
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
File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAdogeskey doge\n" );

require Trog::HV;
require Trog::HV::Libvirt;

# The two facts the generator asks a hypervisor for, answered here so this runs
# on a machine that is not one.
my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
$hv_mock->redefine( virbr_ip  => sub { '192.168.122.1' } );
$hv_mock->redefine( sshd_port => sub { 22 } );

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

my $DOMAIN = 'testdeps.test';

# The makefile generated for one domain whose recipes' testdeps are @testdeps.
sub testdeps_target {
    my (@testdeps) = @_;

    # No recipe in the tree has test dependencies, so every one is given these.
    my $recipe_mock = Test::MockModule->new('Provisioner::Recipe');
    $recipe_mock->redefine( testdeps => sub { return @testdeps } );

    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/domains";
    mkdir "$tmpdir/data";
    mkdir "$tmpdir/data/$DOMAIN";

    my $pool = join( ' ', map { "192.168.1.$_" } 100 .. 199 );

    # One resolver on purpose, written as a scalar rather than a list.  That is
    # what an operator writes, and bin/new_config dereferenced it raw when it
    # wrote provision.conf -- so generating from this is what catches it coming
    # back.
    my %global = (
        data_source    => "$tmpdir/data",
        basedir        => "$tmpdir/domains",
        transfer_user  => 'doge',
        admin_user     => 'doge',
        admin_email    => 'bogus@test.test',
        admin_gecos    => 'Test Test',
        gateway        => '192.168.1.254',
        resolvers      => '192.168.1.254',
        bridge_devname => 'ens4',
        dhcp_devname   => 'ens3',
        ip_pool        => { addresses => $pool },
        nameservers    => { ns1       => 'ns1.test.test', ns2 => 'ns2.test.test' },
    );

    my $recipe_file = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";
    File::Slurper::Temp::write_text( $recipe_file, YAML::XS::Dump( { _base => { _global => \%global }, $DOMAIN => { configd => undef } } ) );
    Provisioner::Cookbook->forget();

    my $err = exception {
        Trog::Provisioner::Config::Generator::main( '--recipes', $recipe_file, '--skip_ssh', $DOMAIN );
    };
    is( $err, undef, 'the generation runs to the end' ) or diag $err;

    my $makefile = "$tmpdir/domains/$DOMAIN/Makefile";
    my $text     = -e $makefile ? File::Slurper::read_text($makefile) : q{};
    my ($target) = $text =~ m{^/etc/provisioner/state/\Q$DOMAIN\E/testdeps:\n((?:\t[^\n]*\n)+)}m;    ## no critic (RegularExpressions::ProhibitComplexRegexes)
    return $target // q{};
}

subtest 'module names: whatever the mirror index names' => sub {
    like( testdeps_target(qw{Test::Deep Test::Differences}), qr/^\tcpanm[ ]--mirror-only[ ]Test::Deep[ ]Test::Differences$/m, 'cpanm is told --mirror-only' );
};

subtest 'a release older than the newest: resolved as before, since the index does not list one' => sub {
    like( testdeps_target( 'Test::Deep', 'Test::Differences@0.69' ), qr/^\tcpanm[ ]Test::Deep[ ]Test::Differences\@0\.69$/m, 'cpanm is not told --mirror-only' );
};

done_testing;
