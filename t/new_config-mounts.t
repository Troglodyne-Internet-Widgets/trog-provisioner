#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/new_config-mounts.t - the mounts target of a generated makefile runs before
every recipe, and only once

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
use Trog::Test::Store();

Trog::Test::Store::throwaway();

# The administrator's keys are read out of the configuration directory now,
# rather than named as an identity for cloud-init to fetch at first boot.
File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAadminskey someadmin\n" );

require Trog::HV;
require Trog::HV::Libvirt;

# The two facts the generator asks a hypervisor for, answered here so this runs
# on a machine that is not one.
my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
$hv_mock->redefine( virbr_ip  => sub { '192.168.122.1' } );
$hv_mock->redefine( sshd_port => sub { 22 } );

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

# The resolvers, the gateway and the pool that the block of the hypervisor
# names, which the local hypervisor of a test has no block for.  See
# Trog::HV/configured_resolvers and Trog::HV/nic_pool.
my $hv_network = Test::MockModule->new('Trog::HV');
$hv_network->redefine( configured_resolvers => sub { return ('192.0.2.254') } );
$hv_network->redefine( static_nics          => sub { return ('br0') } );
$hv_network->redefine( nic_gateway          => sub { return '192.0.2.254' } );
$hv_network->redefine( nic_prefix_length    => sub { return 24 } );
$hv_network->redefine(
    nic_pool => sub {
        return { addresses => [ map { "192.0.2.$_" } 100 .. 199 ] };
    }
);

my $DOMAIN = 'mounts.test';

subtest 'mounts runs after the global targets, and before every recipe' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/domains";
    mkdir "$tmpdir/data";
    mkdir "$tmpdir/data/$DOMAIN";

    my %global = (
        data_source   => "$tmpdir/data",
        basedir       => "$tmpdir/domains",
        transfer_user => 'someadmin',
        admin_user    => 'someadmin',
        admin_email   => 'bogus@test.test',
        admin_gecos   => 'Test Test',
    );

    # A volume of a pool, so that nothing asks the hypervisor about the device.
    my $disk        = { device => 'bogus-volume', mountpoint => '/bogus/mnt', type => 'ext4', options => 'noatime' };
    my $recipe_file = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";
    File::Slurper::Temp::write_text( $recipe_file, YAML::XS::Dump( { _base => { _global => \%global }, $DOMAIN => { configd => undef, mounts => { disks => [$disk] } } } ) );
    Provisioner::Cookbook->forget();

    my $err = exception {
        Trog::Provisioner::Config::Generator::main( '--recipes', $recipe_file, '--skip_ssh', $DOMAIN );
    };
    is( $err, undef, 'the generation runs to the end' ) or diag $err;

    my $makefile = "$tmpdir/domains/$DOMAIN/Makefile";
    my $text     = -e $makefile ? File::Slurper::read_text($makefile) : q{};
    my $S        = "/etc/provisioner/state/$DOMAIN";

    my @rules = $text =~ m{^\Q$S\E/mounts:\n}mg;
    is( scalar @rules, 1, 'the makefile has one mounts target, and not a second among the recipes' );
    my ($mounts) = $text =~ m{^\Q$S\E/mounts:\n((?:\t[^\n]*\n)+)}m;
    like( $mounts // q{}, qr{[ ]bogus-volume[ ]/bogus/mnt[ ]}, 'which mounts the disk' );

    my %before;
    while ( $text =~ m/^(\S+):[ ][|]((?:[ ]\S+)+)$/mg ) {
        $before{$1} = [ split q{ }, $2 ];
    }
    is_deeply( $before{"$S/mounts"}, ["$S/testdeps"], 'mounts waits for the last global target' );
    ok( ( grep { $_ eq "$S/mounts" } @{ $before{"$S/configd"} // [] } ), 'and the recipe waits for mounts' ) or diag explain $before{"$S/configd"};

    # No user, so the admin runs the domain, and cloud-init makes its account
    # with the directory of the domain as its home.
    my $users = YAML::XS::Load( File::Slurper::read_binary("$tmpdir/domains/$DOMAIN/users.yaml") );
    is( $users->{users}[0]{homedir}, "/opt/hosts/$DOMAIN", 'the admin runs the domain, so its home is the directory of the domain' );
};

subtest 'a domain whose admin home is under a share is refused' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/domains";
    mkdir "$tmpdir/data";
    mkdir "$tmpdir/data/$DOMAIN";

    my %global = (
        data_source   => "$tmpdir/data",
        basedir       => "$tmpdir/domains",
        transfer_user => 'someadmin',
        admin_user    => 'someadmin',
        admin_email   => 'bogus@test.test',
        admin_gecos   => 'Test Test',
    );
    my $disk        = { device => 'bogus-volume', mountpoint => '/opt/hosts/', type => 'ext4' };
    my $recipe_file = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";
    File::Slurper::Temp::write_text( $recipe_file, YAML::XS::Dump( { _base => { _global => \%global }, $DOMAIN => { configd => undef, mounts => { disks => [$disk] } } } ) );
    Provisioner::Cookbook->forget();

    my $err = exception {
        Trog::Provisioner::Config::Generator::main( '--recipes', $recipe_file, '--skip_ssh', $DOMAIN );
    };
    like( $err, qr{/opt/hosts/\Q$DOMAIN\E,[ ]is[ ]under},             'the generation names the home' );
    like( $err, qr{the[ ]share[ ]that[ ]mounts[ ]at[ ]/opt/hosts[.]}, 'and the share that would hide it' );
    ok( !-e "$tmpdir/domains/$DOMAIN/Makefile", 'and writes no makefile' );
};

subtest 'share_over' => sub {
    my $mounts = { disks => [ { mountpoint => '/srv/share/' }, { device => 'no-mountpoint' } ], fuse => [ { mountpoint => '/opt/hosts' } ] };
    is( Trog::Provisioner::Config::Generator::share_over( '/srv/share',          $mounts ), '/srv/share', 'the path is the mount point, whatever slash ends it' );
    is( Trog::Provisioner::Config::Generator::share_over( '/srv/share/one.test', $mounts ), '/srv/share', 'and a directory under it' );
    is_deeply( [ Trog::Provisioner::Config::Generator::share_over( '/srv/shared/one.test', $mounts ) ], [], 'but not a directory whose name only begins with the same letters' );
    is_deeply( [ Trog::Provisioner::Config::Generator::share_over( '/opt/hosts/one.test',  $mounts ) ], [], 'and a FUSE mount does not count' );
    is_deeply( [ Trog::Provisioner::Config::Generator::share_over( '/srv/share',           undef ) ],   [], 'and no mounts at all is no share' );
};

done_testing;
