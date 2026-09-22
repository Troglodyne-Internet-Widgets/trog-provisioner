#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/hv-cloud.t - Trog::HV::Cloud: how a guest that a service builds gets
provisioned, and what such a backend refuses to pretend to

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};

use Capture::Tiny qw{capture_stdout};
use Config::Simple();

use FindBin::libs;

use Trog::HV::Cloud();    ## no critic (ProhibitUnusedImports) -- the parent of the test backend below

# The least a backend under Trog::HV::Cloud provides, recording what it was
# asked so that the assertions are about the calls rather than a canned reply.
{

    package Test::Cloud;
    use parent -norequire, 'Trog::HV::Cloud';

    sub new ( $class, %guests ) { return bless { guests => {%guests}, calls => [] }, $class }
    sub describe ($)            { return 'the test cloud' }

    sub domain_exists ( $self, $name ) { die "the test cloud is down\n" if $self->{down}; return exists $self->{guests}{$name} ? 1 : 0 }

    sub create_guest ( $self, %spec ) {
        push @{ $self->{calls} }, [ create_guest => \%spec ];
        $self->{guests}{ $spec{name} } = '203.0.113.7';
        return {};
    }

    sub rebuild_guest ( $self, $name, %spec ) {
        push @{ $self->{calls} }, [ rebuild_guest => $name, \%spec ];
        return {};
    }

    sub guest_ssh_ip ( $self, $config ) { return $self->{guests}{ $config->param('domain') } }

    sub snapshot_names ( $, $ ) { return qw{newest older oldest} }

    sub refusals ($self) { return ( $self->SUPER::refusals, create_disk => 'a disk is a test volume' ) }
}

sub config_for ($domain) {
    my $config = Config::Simple->new( syntax => 'simple' );
    $config->param( domain => $domain );
    return $config;
}

my $SEED = { 'user-data' => "#cloud-config\n" };

subtest 'provision_guest' => sub {
    my $cloud = Test::Cloud->new( 'there.test.test' => '203.0.113.5' );

    my $ip;
    my $out = capture_stdout { $ip = $cloud->provision_guest( config_for('new.test.test'), $SEED ) };
    is_deeply( $cloud->{calls}, [ [ create_guest => { name => 'new.test.test', user_data => "#cloud-config\n" } ] ], 'a guest that is not there is created, with the seed as its payload' );
    is( $ip, '203.0.113.7', 'and its address is what comes back' );
    like( $out, qr/new[.]test[.]test[ ]is[ ]at[ ]203[.]0[.]113[.]7/, 'and printed' );

    $cloud->{calls} = [];
    capture_stdout { $ip = $cloud->provision_guest( config_for('there.test.test'), $SEED ) };
    is_deeply( $cloud->{calls}, [ [ rebuild_guest => 'there.test.test', { user_data => "#cloud-config\n" } ] ], 'a guest that is there is rebuilt, not created beside itself' );
    is( $ip, '203.0.113.5', 'and keeps its address' );

    $cloud->{calls} = [];
    capture_stdout { $ip = $cloud->provision_guest( config_for('there.test.test'), $SEED, reuse => 1 ) };
    is_deeply( $cloud->{calls}, [], 'reuse provisions onto the guest that is there, without a rebuild' );
    is( $ip, '203.0.113.5', 'at the address it already has' );
};

subtest 'would_provision' => sub {
    my $cloud = Test::Cloud->new( 'there.test.test' => '203.0.113.5' );

    my $ip;
    like( capture_stdout { $ip = $cloud->would_provision( config_for('new.test.test') ) }, qr/Would[ ]build[ ]new[.]test[.]test[ ]on[ ]the[ ]test[ ]cloud/, 'a guest that is not there would be built' );
    is( $ip, '(not built)', 'and has no address yet' );

    like( capture_stdout { $ip = $cloud->would_provision( config_for('there.test.test') ) }, qr/Would[ ]rebuild[ ]there/, 'a guest that is there would be rebuilt' );
    is( $ip, '203.0.113.5', 'and has the address it has' );

    like( capture_stdout { $cloud->would_provision( config_for('there.test.test'), reuse => 1 ) }, qr/Would[ ]reprovision[ ]there/, 'or reprovisioned, with reuse' );
    is_deeply( $cloud->{calls}, [], 'and none of it was done' );
};

subtest 'rollback_possible' => sub {
    my $cloud = Test::Cloud->new( 'there.test.test' => '203.0.113.5' );

    ok( $cloud->rollback_possible('there.test.test'),                  'a guest that is there can be put back after a rebuild' );
    ok( !$cloud->rollback_possible('new.test.test'),                   'one that is not cannot' );
    ok( $cloud->rollback_possible( 'there.test.test', capacity => 1 ), 'whatever size the rebuild asks for' );

    $cloud->{down} = 1;
    is( $cloud->rollback_possible('there.test.test'), 0, 'and a service that cannot be asked offers no rollback, rather than dying' );
};

subtest 'snapshot_current_name' => sub {
    is( Test::Cloud->new->snapshot_current_name('there.test.test'), 'newest', 'the newest of snapshot_names' );
};

subtest 'nothing to do' => sub {
    my $cloud = Test::Cloud->new;

    is( $cloud->prepare_host('/bogus/virtiofs-better'), 1, 'no host to prepare' );
    is( $cloud->release_seed('there.test.test'),        1, 'no drive to eject the seed from' );
    is( $cloud->clear_guest('there.test.test'),         1, 'nothing to clear before a rebuild' );
    is_deeply( [ $cloud->guest_volumes('there.test.test') ], [], 'and no volumes left after' );
    is_deeply( $cloud->{calls},                              [], 'none of which asked the service anything' );

    ok( $cloud->is_local && $cloud->builds_by_api && $cloud->manages_addresses, 'local files, guests by API, addresses by the service' );
    is( $cloud->cpu_overcommit, 1, 'and no overcommit on vCPUs the service already counts' );
};

subtest 'check_transfer_ip' => sub {
    my $cloud = Test::Cloud->new;
    $cloud->{transfer_ip} = '192.0.2.10';

    my $result = $cloud->check_transfer_ip;
    ok( $result->{ok}, 'an address named in the block of the hypervisor is enough' );
    like( $result->{what}, qr/192[.]0[.]2[.]10/, 'and is the one named' );
};

subtest 'refusals' => sub {
    my $cloud = Test::Cloud->new;

    my %reasons = $cloud->refusals;
    foreach my $method ( sort keys %reasons ) {
        like( exception { $cloud->$method('there.test.test') }, qr/\ATest::Cloud[ ]has[ ]no[ ]\Q$method\E:[ ]\Q$reasons{$method}\E\n\z/, "$method dies naming itself and why" );
    }

    like( exception { $cloud->create_disk }, qr/a[ ]disk[ ]is[ ]a[ ]test[ ]volume/, 'with the reason a backend overrides' );
    like( exception { $cloud->pool_path },   qr/no[ ]storage[ ]pool/,               'and the generic one where it does not' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
