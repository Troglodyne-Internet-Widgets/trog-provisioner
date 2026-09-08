#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/reseed-ips.t - bin/reseed_ips: what a reseed rebuilds, and what it must not take away

=cut

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Test::More;
use File::Temp();
use File::Slurper::Temp();

use Trog::SQLite();
use Provisioner::IPPool();

require_ok("$FindBin::Bin/../bin/reseed_ips") or die "could not require SUT: $@";

sub fresh_db {
    Trog::SQLite::forget();
    $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/ipmap.cfg", "[global]\ngateway=10.9.9.1\n" );
    return;
}

subtest 'reservations are rebuilt, assignments are not' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10 10.9.9.11 10.9.9.12' };

    Provisioner::IPPool::assign( 'keeper.test', $pool );
    Provisioner::IPPool::reserve( '10.9.9.11', 'insitu:de:ad:be:ef:00:01' );

    # A reservation is a note of what was seen, so a reseed drops it and looks
    # again -- an address that has gone quiet has to come back to the pool.
    is( Provisioner::IPPool::clear_reservations(), 1, 'the reservation went' );

    # An assignment is a decision.  Something has been told it lives there, and
    # a machine being switched off during a sweep is not evidence otherwise.
    is( Provisioner::IPPool::held_by('keeper.test'), '10.9.9.10', 'the assignment did not' );
    is( Provisioner::IPPool::taken()->{'10.9.9.11'}, undef,       'and its address is free again' );
};

subtest 'forgetting the markers is what makes a hypervisor be asked again' => sub {
    fresh_db();
    my $db = Provisioner::IPPool::dbh();

    $db->do("INSERT INTO seeded (source) VALUES ('hv:one')");
    $db->do("INSERT INTO seeded (source) VALUES ('hv:two')");

    is( Provisioner::IPPool::forget_seeding(), 2, 'both were forgotten' );
    is_deeply( $db->selectall_arrayref('SELECT source FROM seeded'), [], 'so the next seed asks them all' );

    # Forgetting nothing is not an error: a reseed of a database that never
    # finished one has markers to clear and should not say so.
    is( Provisioner::IPPool::forget_seeding(), 0, 'and doing it twice is quiet' );
};

subtest 'the report says which way each address went' => sub {
    my %before = ( '10.0.0.1' => 'gone.test', '10.0.0.2' => 'same.test',  '10.0.0.3' => 'insitu:aa' );
    my %after  = ( '10.0.0.2' => 'same.test', '10.0.0.3' => 'moved.test', '10.0.0.4' => 'new.test' );

    my $said = q{};
    {
        ## no critic (InputOutput::ProhibitOneArgSelect, Variables::RequireInitializationForLocalVars)
        open( my $fh, '>', \$said ) or die $!;
        local *STDOUT = $fh;
        Provisioner::Bin::reseed_ips::report( \%before, \%after, 0 );
        close $fh;
    }

    like( $said, qr/10[.]0[.]0[.]4\s+recorded as new[.]test/,          'an address that arrived' );
    like( $said, qr/10[.]0[.]0[.]1\s+freed \(was gone[.]test\)/,       'one that went' );
    like( $said, qr/10[.]0[.]0[.]3\s+now moved[.]test, was insitu:aa/, 'and one that changed hands' );
    like( $said, qr/1 added, 1 freed, 1 changed hands/,                'counted up' );
    unlike( $said, qr/10[.]0[.]0[.]2/, 'while one that did not move is not mentioned' );
};

subtest 'a dry run says would, and a real one does not' => sub {
    my $said = q{};
    {
        ## no critic (InputOutput::ProhibitOneArgSelect, Variables::RequireInitializationForLocalVars)
        open( my $fh, '>', \$said ) or die $!;
        local *STDOUT = $fh;
        Provisioner::Bin::reseed_ips::report( { '10.0.0.1' => 'a.test' }, {}, 1 );
        close $fh;
    }

    like( $said, qr/would be freed/,  'said in the conditional' );
    like( $said, qr/Nothing written/, 'and says so plainly' );
};

done_testing();
