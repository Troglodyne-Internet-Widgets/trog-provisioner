#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/reseed-ips.t - bin/reseed_ips: what a reseed rebuilds, and what it must not take away

=cut

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Test::More;
use Capture::Tiny    qw{capture_stdout};
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp();

use Trog::SQLite();
use Provisioner::IPPool();

require_ok("$FindBin::Bin/../bin/reseed_ips") or die "could not require SUT: $@";

# The database of this machine, which is the database without a fleet, and an
# operation of Provisioner::IPPool::DB on it.
sub local_db () { return Provisioner::IPPool::DB::dbh( Provisioner::IPPool::db_path(), create => 1 ) }
sub local_op ( $op, %args )               { return Provisioner::IPPool::DB::run( Provisioner::IPPool::db_path(), $op, \%args, create => 1 ) }
sub reserve  ( $ip, $name, $nic = undef ) { return local_op( 'reserve', ip => $ip, name => $name, nic => $nic ) }

sub fresh_db {
    Trog::SQLite::forget();
    $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 );    ## no critic (Variables::RequireLocalizedPunctuationVars) -- set for the subtest that called this, after it returns
    return;
}

subtest 'reservations are rebuilt, assignments are not' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10 10.9.9.11 10.9.9.12' };

    Provisioner::IPPool::assign( 'keeper.test', $pool );
    reserve( '10.9.9.11', 'insitu:de:ad:be:ef:00:01' );

    # A reservation is a note of what was seen, so a reseed drops it and looks
    # again -- an address that has gone quiet has to come back to the pool.
    is( local_op('clear_reservations'), 1, 'the reservation went' );

    # An assignment is a decision.  Something has been told it lives there, and
    # a machine being switched off during a sweep is not evidence otherwise.
    is( Provisioner::IPPool::held_by('keeper.test'), '10.9.9.10', 'the assignment did not' );
    is( Provisioner::IPPool::taken()->{'10.9.9.11'}, undef,       'and its address is free again' );
};

subtest 'forgetting the markers is what makes a hypervisor be asked again' => sub {
    fresh_db();
    my $db = local_db();

    $db->do("INSERT INTO seeded (source) VALUES ('hv:one')");
    $db->do("INSERT INTO seeded (source) VALUES ('hv:two')");

    is( local_op('forget_seeding'), 2, 'both were forgotten' );
    is_deeply( $db->selectall_arrayref('SELECT source FROM seeded'), [], 'so the next seed asks them all' );

    # Forgetting nothing is not an error: a reseed of a database that never
    # finished one has markers to clear and should not say so.
    is( local_op('forget_seeding'), 0, 'and doing it twice is quiet' );
};

subtest 'the report says which way each address went' => sub {
    my %before = ( '10.0.0.1' => 'gone.test', '10.0.0.2' => 'same.test',  '10.0.0.3' => 'insitu:aa' );
    my %after  = ( '10.0.0.2' => 'same.test', '10.0.0.3' => 'moved.test', '10.0.0.4' => 'new.test' );

    my ($said) = capture_stdout { Provisioner::Bin::reseed_ips::report( \%before, \%after, 0 ) };

    like( $said, qr/10[.]0[.]0[.]4\s+recorded[ ]as[ ]new[.]test/,            'an address that arrived' );
    like( $said, qr/10[.]0[.]0[.]1\s+freed[ ]\(was[ ]gone[.]test\)/,         'one that went' );
    like( $said, qr/10[.]0[.]0[.]3\s+now[ ]moved[.]test,[ ]was[ ]insitu:aa/, 'and one that changed hands' );
    like( $said, qr/1[ ]added,[ ]1[ ]freed,[ ]1[ ]changed[ ]hands/,          'counted up' );
    unlike( $said, qr/10[.]0[.]0[.]2/, 'while one that did not move is not mentioned' );
};

subtest 'the report names each address that a reseed gave its bridge' => sub {
    my %held     = ( '10.0.0.1' => 'old.test', '10.0.0.2' => 'new.test', '10.0.0.3' => 'still.test' );
    my %on       = ( '10.0.0.1' => q{},        '10.0.0.3' => q{} );
    my %on_after = ( '10.0.0.1' => 'br0',      '10.0.0.2' => 'br0', '10.0.0.3' => q{} );

    my ($said) = capture_stdout { Provisioner::Bin::reseed_ips::report( \%held, \%held, 1, \%on, \%on_after ) };

    like( $said, qr/10[.]0[.]0[.]1\s+would[ ]be[ ]given[ ]the[ ]bridge[ ]br0/, 'an old address that a hypervisor reported on its bridge' );
    like( $said, qr/1[ ]given[ ]a[ ]bridge/,                                   'counted up' );
    unlike( $said, qr/10[.]0[.]0[.][23]/, 'while a new address, and an old one that no hypervisor reported, are not mentioned' );
};

subtest 'a dry run says would, and a real one does not' => sub {
    my ($said) = capture_stdout { Provisioner::Bin::reseed_ips::report( { '10.0.0.1' => 'a.test' }, {}, 1 ) };

    like( $said, qr/would[ ]be[ ]freed/, 'said in the conditional' );
    like( $said, qr/Nothing[ ]written/,  'and says so plainly' );
};

# A fleet of fake hypervisors, each answering guest_names with the names it is
# given.  hv1 is this machine, with no pool, so its database is the one of the
# configuration directory; the others are clouds, which keep none.
sub with_fleet {
    my (%guests) = @_;

    my $fleet = Test::MockModule->new('Trog::Hypervisors');
    $fleet->redefine(
        load => sub {
            return bless { guests => \%guests }, 'Test::FakeFleet';
        }
    );
    return $fleet;
}

subtest 'prune releases only what no hypervisor is running' => sub {
    fresh_db();
    my $pool = { addresses => '10.0.0.1 10.0.0.2 10.0.0.3', bins => { vpnclients => { cidr => '10.8.0.128/29' } } };
    Provisioner::IPPool::assign( $_, $pool ) foreach qw{running.test cloudy.test gone.test};
    Provisioner::IPPool::assign( 'gone.test', $pool, 'vpnclients' );
    reserve( '10.0.0.4', 'gateway:10.0.0.4' );

    my $fleet = with_fleet( hv1 => ['running.test'], hv2 => ['cloudy.test'] );
    my $said  = capture_stdout { is( Provisioner::Bin::reseed_ips::main('--prune'), 0, 'it runs' ) };

    like( $said, qr/10[.]0[.]0[.]3\s+freed[ ][(]was[ ]gone[.]test[)]/, 'the domain that no hypervisor runs is freed' );
    is( Provisioner::IPPool::held_by( 'gone.test', 'vpnclients' ), undef, 'in every bin' );
    is_deeply(
        [ map { Provisioner::IPPool::held_by($_) } qw{running.test cloudy.test} ],
        [qw{10.0.0.1 10.0.0.2}],
        'while a guest on either hypervisor keeps its address'
    );
};

subtest 'a dry run of prune writes nothing' => sub {
    fresh_db();
    Provisioner::IPPool::assign( 'gone.test', { addresses => '10.0.0.3' } );

    my $fleet = with_fleet( hv1 => [] );
    my $said  = capture_stdout { Provisioner::Bin::reseed_ips::main( '--prune', '--dryrun' ) };
    like( $said, qr/would[ ]be[ ]freed/, 'it says what it would free' );
    is( Provisioner::IPPool::held_by('gone.test'), '10.0.0.3', 'and frees nothing' );
};

subtest 'prune refuses when there is no fleet to ask' => sub {
    fresh_db();
    Provisioner::IPPool::assign( 'running.test', { addresses => '10.0.0.1' } );

    my $fleet = with_fleet();
    like( exception { Provisioner::Bin::reseed_ips::main('--prune') }, qr/hypervisors[.]conf/, 'it says what it needs' );
    is( Provisioner::IPPool::held_by('running.test'), '10.0.0.1', 'and releases nothing' );
};

{

    package Test::FakeFleet;

    sub configured ($self) { return scalar keys %{ $self->{guests} } }
    sub names      ($self) { my @names = sort keys %{ $self->{guests} }; return @names }

    sub hypervisor ( $self, $name ) {
        return bless { name => $name, names => $self->{guests}{$name} }, 'Test::FakeHV';
    }

    package Test::FakeHV;

    # guest_names, and not the libvirt handle: a cloud has no vmm.
    sub guest_names       ($self) { return @{ $self->{names} } }
    sub manages_addresses ($self) { return $self->{name} eq 'hv1' ? 0 : 1 }
    sub is_local ($)     { return 1 }
    sub ip_db ($)        { return undef }
    sub static_pools ($) { return {} }
}

done_testing();
