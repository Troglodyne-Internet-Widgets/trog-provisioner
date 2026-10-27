#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

# The generator is loaded when the test runs rather than when it compiles, so
# perl sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/new_config-pool.t - whether bin/new_config gives a guest an address out of the
pool, or leaves it to its lease on the NAT network

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

# A hypervisor that does not give its guests their addresses, as libvirt does
# not, and that stops the run once the address of the guest is settled.
{

    package PoolProbe::HV;
    sub new               { my ( $class, %o ) = @_; return bless {%o}, $class }
    sub manages_addresses { return 0 }
    sub on_nat_network    { my ($self) = @_; return $self->{on_nat_network} }
    sub describe          { return 'hv1' }
    sub virbr_ip          { die "far enough\n" }
}

# Runs the generator for vm.test.test with $pool as the ip_pool of _global, on
# a hypervisor that is or is not on its NAT network.  Returns what it printed,
# what it died with, and the domains that assign was asked about.
sub generate (%args) {
    File::Slurper::Temp::write_text(
        $RECIPES,
        YAML::XS::Dump(
            {
                _base => {
                    _global => {
                        basedir       => '/bogus/domains',
                        transfer_user => 'someadmin',
                        admin_user    => 'someadmin',
                        admin_email   => 'bogus@test.test',
                        admin_gecos   => 'Test Test',
                        gateway       => '192.0.2.254',
                        resolvers     => '192.0.2.254',
                        ( $args{pool} ? ( ip_pool => $args{pool} ) : () ),
                    },
                },
                'vm.test.test' => { ntp => undef },
            }
        )
    );

    my @assigned;
    my $fleet = Test::MockModule->new('Trog::Hypervisors');
    $fleet->redefine( choose => sub { return PoolProbe::HV->new( on_nat_network => $args{on_nat_network} ) } );
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( ensure_seeded => sub { return 0 } );
    $pool->redefine( assign        => sub ( $domain, @ ) { push @assigned, $domain; return '192.0.2.10' } );
    $pool->redefine( assignments   => sub { return {} } );

    Provisioner::Cookbook->forget();
    my $died;
    my $said = capture_stdout {
        $died = exception { Trog::Provisioner::Config::Generator::main( '--recipes', $RECIPES, '--skip_ssh', 'vm.test.test' ) }
    };
    return ( $said, $died // q{}, \@assigned );
}

subtest 'a pool with addresses gives the guest one, as it always did' => sub {
    my ( undef, $died, $assigned ) = generate( pool => { cidr => '192.0.2.0/24' }, on_nat_network => 0 );
    like( $died, qr/\Afar[ ]enough$/m, 'got past the address, on a hypervisor whose NAT network this machine is not on' );
    is_deeply( $assigned, ['vm.test.test'], 'out of the pool' );
};

subtest 'a pool with no addresses leaves the guest to its lease' => sub {
    foreach my $pool ( undef, { addresses => [], cidr => q{} } ) {
        my $which = defined $pool ? 'a pool that names nothing' : 'no pool at all';
        my ( $said, $died, $assigned ) = generate( pool => $pool, on_nat_network => 1 );
        like( $died, qr/\Afar[ ]enough$/m, "got past the address, with $which" );
        is_deeply( $assigned, [], 'without asking the pool for one' );
        like( $said, qr/takes[ ]a[ ]lease[ ]on[ ]the[ ]NAT[ ]network[ ]of[ ]hv1/, 'and says where its address comes from' );
    }
};

subtest 'unless this machine could not reach that lease' => sub {
    my ( undef, $died, $assigned ) = generate( pool => { addresses => [] }, on_nat_network => 0 );
    like( $died, qr/this[ ]machine[ ]is[ ]not[ ]on[ ]that[ ]network/, 'it is refused before anything is built' );
    like( $died, qr/Give[ ]ip_pool[ ]addresses/,                      'naming the fix' );
    is_deeply( $assigned, [], 'and the pool was not asked' );
};

done_testing();
