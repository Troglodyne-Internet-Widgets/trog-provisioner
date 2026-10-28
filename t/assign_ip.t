#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/assign_ip.t - bin/assign_ip: an address of the guests comes from the pool of
the hypervisor that it names, and one of another bin from _global

=cut

use FindBin;
use FindBin::libs;

# Never the real configuration of the installation: this reads recipes.yaml for
# the bins, and the address database beside it.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Test::More;
use Test::MockModule qw{strict};
use Capture::Tiny    qw{capture};
use IPC::Run3();
use File::Slurper::Temp();
use YAML::XS();

use Provisioner::Cookbook();

my %BINS = ( vpnclients => { cidr => '10.8.0.128/30', via => 'vpn.test.test' } );

my $script = "$FindBin::Bin/../bin/assign_ip";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

File::Slurper::Temp::write_text(
    "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml",
    YAML::XS::Dump(
        {
            _base => {
                _global => {
                    basedir     => '/bogus',
                    admin_user  => 'someadmin',
                    admin_gecos => 'Some Admin',
                    admin_email => 'someadmin@test.test',
                    ip_pool     => { bins => \%BINS },
                },
            },
        }
    )
);
Provisioner::Cookbook->forget();

# A hypervisor that answers only for its pool.
{

    package AssignProbe::HV;
    sub new ( $class, %said ) { return bless {%said}, $class }
    sub manages_addresses     { return 0 }
    sub guest_pool ($self)    { return $self->{pool} }

    package AssignProbe::Fleet;
    sub new        ( $class, %hvs ) { return bless {%hvs}, $class }
    sub hypervisor ( $self, $name ) { return $self->{$name} // die "no block $name\n" }
}

my $fleet = Test::MockModule->new('Trog::Hypervisors');
$fleet->redefine( load => sub { return AssignProbe::Fleet->new( hv1 => AssignProbe::HV->new( pool => { cidr => ['192.0.2.0/28'] } ) ) } );

my @asked;
my $pool = Test::MockModule->new('Provisioner::IPPool');
$pool->redefine( ensure_seeded => sub { return 0 } );
$pool->redefine( assign        => sub ( $domain, $from, $bin ) { push( @asked, [ $domain, $from, $bin ] ); return '192.0.2.5' } );

# Runs it with @args, and returns what it printed, what it said on stderr, and
# what main returned.
sub run (@args) {
    @asked = ();
    return capture { Provisioner::Bin::assign_ip::main(@args) };
}

subtest 'an address of the guests comes from the pool of the hypervisor it names' => sub {
    my ( $out, $err, $rc ) = run(qw{--hypervisor hv1 guest.test.test});
    is( $rc,  0,             'it exits 0' ) or diag $err;
    is( $out, "192.0.2.5\n", 'and prints the address' );
    is_deeply( \@asked, [ [ 'guest.test.test', { cidr => ['192.0.2.0/28'], bins => \%BINS }, undef ] ], 'out of the pool of hv1, beside the bins of _global' );
};

subtest 'an address of another bin comes from _global' => sub {
    my ( undef, $err, $rc ) = run(qw{--bin vpnclients laptop.test.test});
    is( $rc, 0, 'it exits 0' ) or diag $err;
    is_deeply( \@asked, [ [ 'laptop.test.test', { bins => \%BINS }, 'vpnclients' ] ], 'with no guests bin in the pool' );
};

# pod2usage exits, so these have to be real runs.  Both refusals come before
# anything is read.
subtest 'which hypervisor is said for the guests, and only for them' => sub {
    my $said = q{};
    IPC::Run3::run3( [ $^X, $script, 'guest.test.test' ], \undef, \$said, \$said );
    isnt( $?, 0, 'an address of the guests with no hypervisor is refused' );
    like( $said, qr/so[ ]name[ ]it[ ]with[ ]--hypervisor/, 'and says why' );

    IPC::Run3::run3( [ $^X, $script, qw{--bin vpnclients --hypervisor hv1 laptop.test.test} ], \undef, \$said, \$said );
    isnt( $?, 0, 'and so is a hypervisor for a bin that belongs to none' );
    like( $said, qr/belongs[ ]to[ ]no[ ]hypervisor/, 'which it says' );
};

done_testing;
