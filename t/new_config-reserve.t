#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

# The generator is loaded when the test runs rather than when it compiles, so
# perl sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/new_config-reserve.t - whether bin/new_config reserves a guest on a
hypervisor that gives its guests their addresses, and names the address of the
guest as main_ip

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
use Capture::Tiny    qw{capture_stdout};
use File::Slurper::Temp();
use YAML::XS();

use Provisioner::Cookbook();

File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAadminskey someadmin\n" );

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

my $RECIPES = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";

# A hypervisor that gives its guests their addresses, as Linode does, and that
# records what it was asked to reserve.
{

    package CloudProbe::HV;
    sub configured_resolvers { return ('192.0.2.254') }
    sub new                  { my ( $class, %o ) = @_; return bless { reserved => [], %o }, $class }
    sub manages_addresses    { return 1 }
    sub size_key             { return 'linode_type' }
    sub describe             { return 'cloud1' }
    sub guest_disks          { return ('sd*') }
    sub name                 { return 'cloud1' }
    sub domain_exists        { my ($self) = @_; return $self->{exists} }
    sub is_reservation       { my ($self) = @_; return $self->{reservation} }
    sub guest_ssh_ip         { return '203.0.113.5' }

    sub reserve_guest {
        my ( $self, %spec ) = @_;
        push @{ $self->{reserved} }, \%spec;
        @$self{qw{exists reservation}} = ( 1, 1 );
        return 1;
    }
}

# Runs the generator for vm.test.test with @flags, on $hv, as far as the
# address of the guest.  Returns what it printed, the main_ip of the
# configuration, what it died with past that point, and the ipmap.
sub generate ( $hv, @flags ) {
    File::Slurper::Temp::write_text(
        $RECIPES,
        YAML::XS::Dump(
            {
                _base => {
                    _global => {
                        basedir       => File::Temp::tempdir( CLEANUP => 1 ),
                        data_source   => File::Temp::tempdir( CLEANUP => 1 ),
                        transfer_user => 'someadmin',
                        admin_user    => 'someadmin',
                        admin_email   => 'bogus@test.test',
                        admin_gecos   => 'Test Test',
                        gateway       => '192.0.2.254',
                        linode_type   => 'g6-nanode-1',
                    },
                },
                'vm.test.test' => { ntp => undef },
            }
        )
    );

    my $main_ip;
    my $ipmap;
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( assignments => sub { return { 'cache.test.test' => '192.0.2.10' } } );
    my $fleet = Test::MockModule->new('Trog::Hypervisors');
    $fleet->redefine( choose => sub { return $hv } );
    my $generator = Test::MockModule->new( 'Trog::Provisioner::Config::Generator', no_auto => 1 );
    $generator->redefine( transfer_to           => sub { return ( ['198.51.100.1'], 22, 'someadmin' ) } );
    $generator->redefine( apply_global_defaults => sub ( $distro, $global ) { $main_ip = $global->{main_ip}; $ipmap = $global->{ipmap}; die "far enough\n" } );

    Provisioner::Cookbook->forget();
    my $died;
    my $said = capture_stdout {
        $died = exception { Trog::Provisioner::Config::Generator::main( '--recipes', $RECIPES, '--skip_ssh', @flags, 'vm.test.test' ) }
    };
    return ( $said, $main_ip, $died // q{}, $ipmap );
}

subtest 'a build reserves a guest that does not exist, and names its address' => sub {
    my $hv = CloudProbe::HV->new( exists => 0 );
    my ( $said, $main_ip, $died ) = generate( $hv, '--reserve' );
    like( $died, qr/\Afar[ ]enough$/m, 'got as far as the address' );
    is_deeply( $hv->{reserved}, [ { name => 'vm.test.test', size => 'g6-nanode-1' } ], 'the guest was reserved, of the type that the configuration names' );
    is( $main_ip, '203.0.113.5', 'and its address is the main_ip' );
    like( $said, qr/Reserved[ ]vm[.]test[.]test[ ]on[ ]cloud1/, 'and it says so' );
};

subtest 'nothing is reserved without the option, or on a dry run' => sub {
    foreach my $flags ( [], [qw{--reserve --dryrun}] ) {
        my $hv   = CloudProbe::HV->new( exists => 0 );
        my $what = @$flags ? 'a dry run' : 'a run without --reserve';
        my ( undef, $main_ip ) = generate( $hv, @$flags );
        is_deeply( $hv->{reserved}, [], "$what makes no guest" );
        is( $main_ip, undef, 'and there is no address to name' );
    }
};

subtest 'a guest that exists is not reserved again, and its address is the main_ip' => sub {
    my $hv = CloudProbe::HV->new( exists => 1 );
    my ( undef, $main_ip, undef, $ipmap ) = generate( $hv, '--reserve' );
    is_deeply( $hv->{reserved}, [], 'no second reservation' );
    is( $main_ip, '203.0.113.5', 'the address that the hypervisor gave it' );
    is_deeply( $ipmap, { 'cache.test.test' => '192.0.2.10' }, 'and the guests of the pool are in its ipmap, which a VPN client reaches' );
};

done_testing;
