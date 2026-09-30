#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-IPPool.t - the static address pool: parsing it, and handing out of it

=cut

use Test::More;
use Test::Fatal;
use Test::MockModule qw{strict};
use File::Temp();
use POSIX();

use FindBin::libs;
use Trog::SQLite();

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use_ok('Provisioner::IPPool');

subtest 'pool_ips: explicit addresses' => sub {
    my @ips = Provisioner::IPPool::pool_ips( { addresses => '10.0.0.1 10.0.0.2 10.0.0.3' } );
    is_deeply \@ips, [qw{10.0.0.1 10.0.0.2 10.0.0.3}], 'parses space-separated addresses';
};

subtest 'pool_ips: a pool written as YAML lists' => sub {
    my @ips = Provisioner::IPPool::pool_ips( { addresses => [qw{10.0.0.1 10.0.0.2}], cidr => ['192.0.2.0/30'] } );
    is_deeply \@ips, [qw{10.0.0.1 10.0.0.2 192.0.2.1 192.0.2.2}], 'a list is a list, as an operator writes one';
};

subtest 'pool_ips: CIDR expansion' => sub {
    my @ips = Provisioner::IPPool::pool_ips( { cidr => '192.0.2.0/30' } );
    ok scalar(@ips) >= 2, 'expands CIDR to multiple IPs';
    like $ips[0], qr/^192\.0\.2\./, 'IPs are in correct subnet';
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
    $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 );    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the subtest that called this reads it afterwards, which local would undo
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
    like( exception { Provisioner::IPPool::assign( 'b.test', $pool ) }, qr/pool[ ]exhausted/, 'says so' );
};

subtest 'assign: dies when no pool is configured' => sub {
    fresh_db();
    like( exception { Provisioner::IPPool::assign( 'a.test', {} ) }, qr/No[ ]\[ip_pool\][ ]section/, 'says so' );
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

{
    # A stand-in hypervisor, which is also its own libvirt connection.  The
    # sweep is the command that pings, and the other command lists the guests.
    package FakeHV;
    sub new ( $class, %said ) { return bless {%said}, $class }
    sub manages_addresses     { return 0 }
    sub bridge_device ($self)         { return $self->{bridge} // die "no bridge\n" }
    sub capture_cmd   ( $self, $cmd ) { return $cmd =~ m/ping/ ? $self->{sweep} : $self->{guests} }
    sub vmm           ($self)         { return $self }

    sub list_all_domains ($self) {
        return map { FakeDomain->new($_) } @{ $self->{names} };
    }
    sub domain_dir       { return '/bogus' }
    sub ssh_host ($self) { return $self->{host} }

    package FakeDomain;
    sub new      ( $class, $name ) { return bless { name => $name }, $class }
    sub get_name ($self)           { return $self->{name} }

    package FakeFleet;
    sub new ( $class, %hvs ) { return bless {%hvs}, $class }
    sub configured           { return 1 }
    sub names      ($self)       { my @names = sort keys %$self; return @names }
    sub hypervisor ( $self, $n ) { return $self->{$n} }
}

# Seeds from one stand-in hypervisor named hv1, and returns what seed returned.
sub seed_from ( $pool, $gateway, %said ) {
    my $mock = Test::MockModule->new('Trog::Hypervisors');
    $mock->redefine( load => sub { return FakeFleet->new( hv1 => FakeHV->new(%said) ) } );
    return Provisioner::IPPool::seed( $pool, $gateway );
}

subtest 'seed: what is answering on the wire' => sub {
    fresh_db();

    # Two signals, because one is not trustworthy alone.  The sweep says which
    # addresses answered, which is deterministic; the neighbour table is
    # consulted for a second opinion and for the hardware address, because its
    # entries decay to STALE between the sweep and the read.
    my $recorded = seed_from(
        { cidr => '192.0.2.32/27' },
        '192.0.2.62',
        bridge => 'br0',
        host   => '192.0.2.33',
        names  => [qw{guest.test quiet.test}],
        guests => "guest.test\t192.0.2.40\nquiet.test\t\nguest.test\t10.0.0.9\nguest.test\t192.0.2.40\n",
        sweep  => <<'SAID',
LIVE 192.0.2.40
LIVE 192.0.2.43
LIVE 192.0.2.50
LIVE 192.0.2.54
192.0.2.1 FAILED
192.0.2.40 lladdr 52:54:00:12:34:56 REACHABLE
192.0.2.43 lladdr 52:54:00:e7:46:8f REACHABLE
192.0.2.54 lladdr ce:f9:56:8c:db:2b STALE
192.0.2.55 lladdr 52:54:00:aa:bb:cc REACHABLE
192.0.2.59 lladdr 52:54:00:de:ad:01 STALE
192.0.2.61 lladdr 52:54:00:00:00:01 INCOMPLETE
SAID
    );

    my $taken = Provisioner::IPPool::taken();

    is( $taken->{'192.0.2.62'}, 'gateway:192.0.2.62', 'the gateway is reserved as the gateway' );
    is( $taken->{'192.0.2.33'}, 'hv:hv1',             'the hypervisor is reserved under its name' );

    # The NAT address of a guest is libvirt's to give out, and a guest named
    # twice, from its provision.conf and from libvirt, is one row.
    is( $taken->{'192.0.2.40'}, 'guest.test', 'a guest is recorded at its address, which is not a machine that answered' );
    ok( !exists $taken->{'10.0.0.9'}, 'and an address outside the pool is not recorded' );

    # .43 answered and is REACHABLE.  .54 answered but has gone STALE, which is
    # exactly the decay the ping result is there to survive.  .55 did not answer
    # but is REACHABLE, so something is there that does not speak ICMP.
    is( $taken->{'192.0.2.43'}, 'insitu:52:54:00:e7:46:8f', 'what answered and is reachable is reserved' );
    is( $taken->{'192.0.2.54'}, 'insitu:ce:f9:56:8c:db:2b', 'and the hardware address comes off the table even when the entry is stale' );
    is( $taken->{'192.0.2.55'}, 'insitu:52:54:00:aa:bb:cc', 'what is reachable and did not answer is reserved' );
    is( $taken->{'192.0.2.50'}, 'insitu:unknown',           'and what answered with no entry in the table has no hardware address' );

    # STALE without an answer is not a signal: it outlives the machine that put
    # it there, and .59 is an address a guest destroyed days ago used to have.
    ok( !exists $taken->{'192.0.2.59'}, 'a leftover entry is not read as occupied' );
    ok( !exists $taken->{'192.0.2.61'}, 'nor is one that never completed' );

    is( $recorded, scalar keys %$taken, 'and it counts each row it wrote' );
    is_deeply( Provisioner::IPPool::dbh()->selectall_arrayref('SELECT source FROM seeded'), [ ['hv:hv1'] ], 'the hypervisor is marked as seeded' );
};

subtest 'seed: a hypervisor with no bridge is not swept' => sub {
    fresh_db();

    # A hypervisor that will not say what bridge it is on cannot be asked what
    # is on it, and that is not a reason to stop seeding.
    my $recorded = seed_from(
        { cidr => '192.0.2.32/27' },
        undef,
        names  => ['guest.test'],
        guests => "guest.test\t192.0.2.40\n",
        sweep  => "LIVE 192.0.2.43\n",
    );

    is( $recorded, 1, 'one row' );
    is_deeply( Provisioner::IPPool::taken(), { '192.0.2.40' => 'guest.test' }, 'the guest, and no sweep' );
};

subtest 'a seed that could not finish is retried, not remembered' => sub {
    fresh_db();

    # What went wrong in practice: one hypervisor answered, another could not be
    # reached, and the database was left holding a single reservation.  Asking
    # "are there any rows at all" then said it was seeded, so every guest on the
    # fleet stayed missing and no later run went looking again.
    my $db = Provisioner::IPPool::dbh();
    Provisioner::IPPool::reserve( '10.9.9.10', 'hv:somewhere' );

    my $done = $db->selectall_arrayref('SELECT source FROM seeded');
    is_deeply( $done, [], 'a row is not a finished seed' );

    # Only the marker says so, and it is written after the hypervisor has
    # answered everything.
    $db->do("INSERT INTO seeded (source) VALUES ('hv:somewhere')");
    is_deeply(
        $db->selectall_arrayref('SELECT source FROM seeded'),
        [ ['hv:somewhere'] ],
        'and once it has, that hypervisor is not swept again'
    );
};

subtest 'two runs at once cannot be given the same address' => sub {
    fresh_db();

    # The entire reason this is a database.  Forked rather than mocked, because
    # what is being tested is two processes contending for one file -- which is
    # exactly what a fan-out of provisions is, and what the [ips] section could
    # not survive.
    my $pool = { cidr => '10.9.40.0/27' };

    pipe( my $read, my $write ) or die "pipe: $!";

    my @kids;
    foreach my $n ( 1 .. 8 ) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;

        if ( !$pid ) {
            close($read) or die "Could not close the reading end of the pipe: $!";

            # A handle inherited across a fork is the one thing SQLite will not
            # forgive, so each child opens its own.
            Trog::SQLite::forget();
            my $got = eval { Provisioner::IPPool::assign( "d$n.test", $pool ) } // "ERROR: $@";
            print {$write} "$got\n";
            close($write) or die "Could not close the writing end of the pipe: $!";

            POSIX::_exit(0);
        }

        push( @kids, $pid );
    }

    close($write) or die "Could not close the writing end of the pipe: $!";
    my @said = <$read>;
    close($read) or die "Could not close the reading end of the pipe: $!";
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
    # cannot talk to anything.
    my @ips = Provisioner::IPPool::pool_ips( { cidr => '192.0.2.0/26' } );
    is scalar @ips, 62,           'a /26 offers 62 hosts, not 64';
    is $ips[0],     '192.0.2.1',  'starting after the network address';
    is $ips[-1],    '192.0.2.62', 'and stopping before the broadcast';
    ok !( grep { $_ eq '192.0.2.0' } @ips ),  'the network address is not on offer';
    ok !( grep { $_ eq '192.0.2.63' } @ips ), 'nor is the broadcast';

    is_deeply [ Provisioner::IPPool::pool_ips( { cidr => '10.0.0.0/30' } ) ],
      [ '10.0.0.1', '10.0.0.2' ], 'a /30 offers its two hosts';

    # RFC 3021: a /31 is a point to point link and both addresses are usable.
    is_deeply [ Provisioner::IPPool::pool_ips( { cidr => '10.0.0.4/31' } ) ],
      [ '10.0.0.4', '10.0.0.5' ], 'a /31 keeps both';

    is_deeply [ Provisioner::IPPool::pool_ips( { cidr => '10.0.0.9/32' } ) ],
      ['10.0.0.9'], 'and a /32 is the one host it names';

    # An explicit address list is taken at its word; if you wrote it down, you
    # meant it.
    is_deeply [ Provisioner::IPPool::pool_ips( { addresses => '192.0.2.0 192.0.2.5' } ) ],
      [ '192.0.2.0', '192.0.2.5' ], 'addresses given by hand are not second-guessed';
};

done_testing;
