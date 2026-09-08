#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Provisioner-IPPool.t - the static address pool: parsing it, and handing out of it

=cut

use Test::More;
use Test::Fatal;
use File::Temp qw{tempfile};
use File::Slurper::Temp();
use POSIX();

use Trog::SQLite();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use_ok('Provisioner::IPPool');

sub write_ipmap {
    my ($content) = @_;
    my ( $fh, $fname ) = tempfile( SUFFIX => '.cfg', UNLINK => 1 );
    print $fh $content;
    close $fh;
    return $fname;
}

subtest 'pool_ips: explicit addresses' => sub {
    my @ips = Provisioner::IPPool::pool_ips( { addresses => '10.0.0.1 10.0.0.2 10.0.0.3' } );
    is_deeply \@ips, [qw{10.0.0.1 10.0.0.2 10.0.0.3}], 'parses space-separated addresses';
};

subtest 'pool_ips: CIDR expansion' => sub {
    my @ips = Provisioner::IPPool::pool_ips( { cidr => '192.168.1.0/30' } );
    ok scalar(@ips) >= 2, 'expands CIDR to multiple IPs';
    like $ips[0], qr/^192\.168\.1\./, 'IPs are in correct subnet';
};

subtest 'pool_ips: deduplicates overlap' => sub {
    my @ips = Provisioner::IPPool::pool_ips(
        {
            addresses => '10.0.0.1 10.0.0.2',
            cidr      => '10.0.0.0/31',
        }
    );
    my %seen;
    $seen{$_}++ for @ips;
    ok !( grep { $seen{$_} > 1 } keys %seen ), 'no duplicate IPs';
};

# --- Handing addresses out -----------------------------------------------------
#
# The database, not the file.  Two runs cannot share a file: both read it, both
# find the same first free address, both write, and the second write wins -- so
# a fan-out of provisions gives two guests the same address and neither says so.

sub fresh_db {
    Trog::SQLite::forget();

    # A directory per subtest, so one subtest's assignments are not another's.
    $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/ipmap.cfg", "[global]\ngateway=10.9.9.1\n" );
    return;
}

subtest 'assign: picks the first free one' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10 10.9.9.11 10.9.9.12' };

    is( Provisioner::IPPool::assign( 'a.test', $pool ), '10.9.9.10', 'the first' );
    is( Provisioner::IPPool::assign( 'b.test', $pool ), '10.9.9.11', 'then the next' );
};

subtest 'assign: a domain that already has one is answered with it' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10 10.9.9.11' };

    # Idempotent, so re-provisioning does not move a guest to a new address and
    # anything that wants to know can just ask.
    my $first = Provisioner::IPPool::assign( 'a.test', $pool );
    is( Provisioner::IPPool::assign( 'a.test', $pool ), $first,      'the same address' );
    is( Provisioner::IPPool::assign( 'b.test', $pool ), '10.9.9.11', 'and nothing else was consumed' );
};

subtest 'assign: reservations are not handed out' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10 10.9.9.11' };

    # The hypervisor and the gateway live in here so that nothing is ever given
    # an address something else is already answering on.
    is( Provisioner::IPPool::reserve( '10.9.9.10', 'gateway:10.9.9.10' ), 1, 'reserved' );
    is( Provisioner::IPPool::reserve( '10.9.9.10', 'gateway:10.9.9.10' ), 0, 'and saying so twice changes nothing' );

    is( Provisioner::IPPool::assign( 'a.test', $pool ), '10.9.9.11', 'the reserved one is skipped' );
};

subtest 'assign: dies when the pool is exhausted' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10' };

    Provisioner::IPPool::assign( 'a.test', $pool );
    like( exception { Provisioner::IPPool::assign( 'b.test', $pool ) }, qr/pool exhausted/, 'says so' );
};

subtest 'assign: dies when no pool is configured' => sub {
    fresh_db();
    like( exception { Provisioner::IPPool::assign( 'a.test', {} ) }, qr/No \[ip_pool\] section/, 'says so' );
};

subtest 'release: gives it back, and only for a guest' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10 10.9.9.11' };

    my $had = Provisioner::IPPool::assign( 'a.test', $pool );
    is( Provisioner::IPPool::release('a.test'),         $had,  'says what it released' );
    is( Provisioner::IPPool::held_by('a.test'),         undef, 'which it no longer holds' );
    is( Provisioner::IPPool::assign( 'b.test', $pool ), $had,  'and the address is available again' );

    is( Provisioner::IPPool::release('never.test'), undef, 'releasing what was never held is not an error' );

    # A reservation is not a guest, and bin/destroy must not be able to hand the
    # gateway out by being pointed at it.
    Provisioner::IPPool::reserve( '10.9.9.11', 'gateway:10.9.9.11' );
    is( Provisioner::IPPool::release('gateway:10.9.9.11'), undef,               'and a reservation is not released' );
    is( Provisioner::IPPool::taken()->{'10.9.9.11'},       'gateway:10.9.9.11', 'it is still spoken for' );
};

subtest 'assignments: guests only, which is what the zone renders' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10 10.9.9.11' };

    Provisioner::IPPool::assign( 'a.test', $pool );
    Provisioner::IPPool::reserve( '10.9.9.11', 'hv:somewhere' );

    is_deeply( Provisioner::IPPool::assignments(), { 'a.test' => '10.9.9.10' }, 'the reservation is not a domain' );
    is_deeply(
        Provisioner::IPPool::taken(),
        { '10.9.9.10' => 'a.test', '10.9.9.11' => 'hv:somewhere' },
        'though it is certainly taken'
    );
};

subtest 'two runs at once cannot be given the same address' => sub {
    fresh_db();

    # The entire reason this is a database.  Forked rather than mocked, because
    # what is being tested is two processes contending for one file -- which is
    # exactly what a fan-out of provisions is, and what the [ips] section could
    # not survive.
    my $pool = { cidr => '10.9.40.0/27' };
    my $dir  = $ENV{TROG_PROVISIONER_CONFIG};

    pipe( my $read, my $write ) or die "pipe: $!";

    my @kids;
    foreach my $n ( 1 .. 8 ) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;

        if ( !$pid ) {
            close $read;

            # A handle inherited across a fork is the one thing SQLite will not
            # forgive, so each child opens its own.
            Trog::SQLite::forget();
            my $got = eval { Provisioner::IPPool::assign( "d$n.test", $pool ) } // "ERROR: $@";
            print {$write} "$got\n";
            close $write;

            ## no critic (Subroutines::ProhibitCallsToUnexportedSubs)
            POSIX::_exit(0);
        }

        push( @kids, $pid );
    }

    close $write;
    my @said = <$read>;
    close $read;
    waitpid( $_, 0 ) for @kids;

    chomp @said;
    is( scalar @said, 8, 'every one of them got an answer' );
    unlike( join( ',', @said ), qr/ERROR/, 'and none of them failed' ) or diag join( "\n", @said );

    my %seen;
    my @twice = grep { $seen{$_}++ } @said;
    is_deeply( \@twice, [], 'no address was handed out twice' ) or diag join( ',', sort @said );
};

subtest 'pool_ips leaves the network and broadcast addresses alone' => sub {

    # A guest handed .0 or .63 of a /26 looks provisioned right up until it
    # cannot talk to anything.  This is where staging.troglodyne.net=192.168.1.0
    # came from.
    my @ips = Provisioner::IPPool::pool_ips( { cidr => '192.168.1.0/26' } );
    is scalar @ips, 62,             'a /26 offers 62 hosts, not 64';
    is $ips[0],     '192.168.1.1',  'starting after the network address';
    is $ips[-1],    '192.168.1.62', 'and stopping before the broadcast';
    ok !( grep { $_ eq '192.168.1.0' } @ips ),  'the network address is not on offer';
    ok !( grep { $_ eq '192.168.1.63' } @ips ), 'nor is the broadcast';

    is_deeply [ Provisioner::IPPool::pool_ips( { cidr => '10.0.0.0/30' } ) ],
      [ '10.0.0.1', '10.0.0.2' ], 'a /30 offers its two hosts';

    # RFC 3021: a /31 is a point to point link and both addresses are usable.
    is_deeply [ Provisioner::IPPool::pool_ips( { cidr => '10.0.0.4/31' } ) ],
      [ '10.0.0.4', '10.0.0.5' ], 'a /31 keeps both';

    is_deeply [ Provisioner::IPPool::pool_ips( { cidr => '10.0.0.9/32' } ) ],
      ['10.0.0.9'], 'and a /32 is the one host it names';

    # An explicit address list is taken at its word; if you wrote it down, you
    # meant it.
    is_deeply [ Provisioner::IPPool::pool_ips( { addresses => '192.168.1.0 192.168.1.5' } ) ],
      [ '192.168.1.0', '192.168.1.5' ], 'addresses given by hand are not second-guessed';
};

done_testing;
