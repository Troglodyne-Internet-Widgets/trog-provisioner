#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/list_ip_pool.t - bin/list_ip_pool: a guests bin for each network, and a bin
with via shows what its server gave out by hand, and warns when the server
cannot be asked

=cut

use FindBin;
use FindBin::libs;

# Never the installation's real configuration: this reads recipes.yaml for the
# pool, and the address database beside it.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Test::More;
use Test::MockModule qw{strict};
use Capture::Tiny    qw{capture};
use File::Slurper::Temp();
use YAML::XS();

use Provisioner::Cookbook();

my %GLOBAL = (
    basedir     => '/bogus',
    admin_user  => 'someadmin',
    admin_gecos => 'Some Admin',
    admin_email => 'someadmin@test.test',
    ip_pool     => { bins => { vpnclients => { cidr => '10.8.0.128/30', via => 'vpn.test.test' } } },
);

my $script = "$FindBin::Bin/../bin/list_ip_pool";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", YAML::XS::Dump( { _base => { _global => \%GLOBAL } } ) );
Provisioner::Cookbook->forget();

my $pool = Test::MockModule->new('Provisioner::IPPool');
$pool->redefine( ensure_seeded => sub { return 0 } );

# Two hypervisors on one network, and one on another.
$pool->redefine( guest_pools => sub { return ( hv1 => { addresses => ['192.0.2.10'] }, hv2 => { addresses => ['192.0.2.10'] }, far => { cidr => ['198.51.100.0/30'] } ) } );

subtest 'each network has a guests bin, named for the hypervisors on it' => sub {
    $pool->redefine( via_clients => sub { return () } );

    my ( $out, $err, $rc ) = capture { Provisioner::Bin::list_ip_pool::main() };
    is( $rc, 0, 'it exits 0' ) or diag $err;
    like( $out, qr/^Bin[ ]guests:hv1,hv2:[ ]+1[ ]total/m, 'the hypervisors that share a pool share its bin' )           or diag $out;
    like( $out, qr/^Bin[ ]guests:far:[ ]+2[ ]total/m,     'and the other network has its own, with its own addresses' ) or diag $out;
    like( $out, qr/^Bin[ ]vpnclients:/m,                  'beside the bins of _global' );
};

subtest 'the server of a bin with via is asked what it gave out' => sub {
    my @asked;
    $pool->redefine( via_clients => sub { push( @asked, $_[0] ); return ( 'laptop.test' => '10.8.0.129' ) } );

    my ( $out, $err, $rc ) = capture { Provisioner::Bin::list_ip_pool::main() };
    is( $rc, 0, 'it exits 0' ) or diag $err;
    is_deeply( \@asked, ['vpn.test.test'], 'the server of the bin is asked, and nobody for the guests' );
    like( $out, qr/^[ ]+10[.]8[.]0[.]129[ ]+vpnclient:laptop[.]test$/m, 'and the address it gave out by hand shows as taken' ) or diag $out;
};

subtest 'a server that cannot be asked is a warning, not a stop' => sub {
    $pool->redefine( via_clients => sub { die "vpn.test.test is not up\n" } );

    my ( $out, $err, $rc ) = capture { Provisioner::Bin::list_ip_pool::main() };
    is( $rc, 0, 'it exits 0' );
    like( $err, qr/bin[ ]vpnclients[ ]shows[ ]only/,   'it says which bin is incomplete' );
    like( $err, qr/vpn[.]test[.]test[ ]is[ ]not[ ]up/, 'and why' );
    like( $out, qr/^Bin[ ]vpnclients:/m,               'and still lists the bin' );
};

done_testing;
