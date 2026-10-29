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

subtest 'guest_address: the guest that runs a domain, and its address' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10 10.9.9.11' };
    Provisioner::IPPool::assign( 'host.test', $pool );

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( host_of => sub { my ( undef, $domain ) = @_; return $domain eq 'layered.test' ? 'host.test' : () } );

    is_deeply( [ Provisioner::IPPool::guest_address('host.test') ],    [ 'host.test', '10.9.9.10' ], 'a domain with a guest of its own' );
    is_deeply( [ Provisioner::IPPool::guest_address('layered.test') ], [ 'host.test', '10.9.9.10' ], 'a domain built onto another guest, at the address of that guest' );
    is_deeply( [ Provisioner::IPPool::guest_address('none.test') ],    [ 'none.test', undef ],       'and a guest with no address, which the caller names' );
};

subtest 'reachable_address: the guests reach a guest through its tunnel when it has one' => sub {
    my %held;
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( holdings => sub { return {%held} } );

    %held = ( guests => '192.0.2.5' );
    is( Provisioner::IPPool::reachable_address('relay.test'), '192.0.2.5', 'a guest on the LAN, at its address there' );

    %held = ( guests => '192.0.2.5', vpnclients => '198.51.100.5' );
    is( Provisioner::IPPool::reachable_address('relay.test'), '198.51.100.5', 'a guest that is a client of the VPN, at its address there' );

    %held = ( vpnclients => '198.51.100.5', others => '203.0.113.5' );
    like( exception { Provisioner::IPPool::reachable_address('relay.test') }, qr/an[ ]address[ ]in[ ]each[ ]of[ ]others,[ ]vpnclients/, 'two tunnels are a question it does not guess at' );

    %held = ();
    like( exception { Provisioner::IPPool::reachable_address('relay.test') }, qr/relay[.]test[ ]has[ ]no[ ]address/, 'and a guest with no address stops the build' );
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

subtest 'offers: whether a bin has an address to give out' => sub {
    ok( Provisioner::IPPool::offers( { cidr => '192.0.2.0/30' } ),                              'a block' );
    ok( Provisioner::IPPool::offers( { addresses => '192.0.2.7' } ),                            'one address' );
    ok( !Provisioner::IPPool::offers( {} ),                                                     'no pool at all' );
    ok( !Provisioner::IPPool::offers( { addresses => [], cidr => [] } ),                        'a pool that names nothing' );
    ok( !Provisioner::IPPool::offers( { addresses => q{}, cidr => q{ } } ),                     'or names nothing in a string' );
    ok( !Provisioner::IPPool::offers( { bins => { vpn => { cidr => '10.8.0.0/30' } } } ),       'another bin is not the guests' );
    ok( Provisioner::IPPool::offers( { bins => { vpn => { cidr => '10.8.0.0/30' } } }, 'vpn' ), 'unless that is the bin asked about' );
};

subtest 'release: gives it back, and only for a guest' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10 10.9.9.11' };

    my $had = Provisioner::IPPool::assign( 'a.test', $pool );
    is_deeply( Provisioner::IPPool::release('a.test'), { guests => $had }, 'says what it released' );
    is( Provisioner::IPPool::held_by('a.test'),         undef, 'which it no longer holds' );
    is( Provisioner::IPPool::assign( 'b.test', $pool ), $had,  'and the address is available again' );

    is_deeply( Provisioner::IPPool::release('never.test'), {}, 'releasing what was never held is not an error' );

    # A reservation is not a guest, and bin/destroy must not be able to hand the
    # gateway out by being pointed at it.
    Provisioner::IPPool::reserve( '10.9.9.11', 'gateway:10.9.9.11' );
    is_deeply( Provisioner::IPPool::release('gateway:10.9.9.11'), {}, 'and a reservation is not released' );
    is( Provisioner::IPPool::taken()->{'10.9.9.11'}, 'gateway:10.9.9.11', 'it is still spoken for' );
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

# --- Bins ----------------------------------------------------------------------
#
# A bin is a named part of the pool that hands out only its own addresses, so
# that the VPN clients cannot take the last address a guest needs, or the other
# way about.

subtest 'bins: the top of the pool is the bin of the guests' => sub {
    my %bins = Provisioner::IPPool::bins( { addresses => '10.9.9.10', bins => { vpnclients => { cidr => '10.8.0.128/30' } } } );
    is_deeply( [ sort keys %bins ],                                    [qw{guests vpnclients}],     'both bins' );
    is_deeply( [ Provisioner::IPPool::pool_ips( $bins{guests} ) ],     ['10.9.9.10'],               'the guests have the addresses at the top' );
    is_deeply( [ Provisioner::IPPool::pool_ips( $bins{vpnclients} ) ], [qw{10.8.0.129 10.8.0.130}], 'and the clients have their own block' );

    is_deeply( { Provisioner::IPPool::bins( {} ) }, {}, 'an empty pool has no bins' );
};

subtest 'bins: refused when they cannot be told apart' => sub {
    like(
        exception { Provisioner::IPPool::bins( { addresses => '10.9.9.10', bins => { guests => { addresses => '10.9.9.11' } } } ) },
        qr/top[ ]of[ ]ip_pool .* bin[ ]named[ ]guests/,
        'addresses at the top and a guests bin are two answers to one question'
    );
    is(
        exception { Provisioner::IPPool::bins( { cidr => '10.9.9.0/30', bins => { vpnclients => { addresses => '10.9.9.2' } } } ) },
        "ip_pool has 10.9.9.2/32 in the bin vpnclients and 10.9.9.0/30 in the bin guests, which overlap, and an address can belong to one bin only\n",
        'and an address in two bins names both blocks and both bins'
    );
    like(
        exception { Provisioner::IPPool::bins( { cidr => '10.9.0.0/16', bins => { vpnclients => { cidr => '10.9.200.0/24' } } } ) },
        qr/which[ ]overlap/,
        'and so is a block inside the block of another bin, without a look at each address'
    );
    is( exception { Provisioner::IPPool::bins( { cidr => '10.9.9.0/30', bins => { vpnclients => { cidr => '10.9.9.4/30' } } } ) }, undef, 'two blocks side by side do not overlap' );
    like( exception { Provisioner::IPPool::bins( { bins => { vpnclients => { addresses => 'bogus' } } } ) }, qr/Invalid[ ]CIDR[ ]'bogus\/32'[ ]in[ ]the[ ]bin[ ]vpnclients/, 'and an address that is not one is refused, with the bin that holds it' );
};

subtest 'bins_via and blocks: the bins that a guest routes to, as networks' => sub {
    my $pool = {
        cidr => '10.9.9.0/30',
        bins => {
            vpnclients => { cidr => '10.8.0.128/25', addresses => [qw{10.8.1.7 10.8.1.8}], via => 'vpn.test.test' },
            other      => { cidr => '10.7.0.0/30',   via => 'elsewhere.test.test' },
            plain      => { cidr => '10.6.0.0/30' },
        },
    };

    my %via = Provisioner::IPPool::bins_via( $pool, 'vpn.test.test' );
    is_deeply( [ keys %via ],                                                  ['vpnclients'],                              'only the bin that names the guest' );
    is_deeply( [ Provisioner::IPPool::blocks( $via{vpnclients} ) ],            [qw{10.8.0.128/25 10.8.1.7/32 10.8.1.8/32}], 'its cidr as it is, and each address as a /32' );
    is_deeply( { Provisioner::IPPool::bins_via( $pool, 'nobody.test.test' ) }, {},                                          'a guest that no bin names routes to none' );
    is_deeply( { Provisioner::IPPool::bins_via( $pool, q{} ) },                {},                                          'and a bin without via is not one that the empty name routes to' );
};

subtest 'assign: each bin hands out only its own addresses' => sub {
    fresh_db();
    my $pool = { addresses => '10.9.9.10', bins => { vpnclients => { addresses => '10.8.0.130 10.8.0.131' } } };

    is( Provisioner::IPPool::assign( 'a.test', $pool ),               '10.9.9.10',  'a guest gets a guest address' );
    is( Provisioner::IPPool::assign( 'a.test', $pool, 'vpnclients' ), '10.8.0.130', 'and the same domain gets a client address beside it' );
    is( Provisioner::IPPool::assign( 'a.test', $pool, 'vpnclients' ), '10.8.0.130', 'which it keeps' );
    is( Provisioner::IPPool::held_by( 'a.test', 'vpnclients' ),       '10.8.0.130', 'and which held_by reports for that bin' );
    is( Provisioner::IPPool::held_by('a.test'),                       '10.9.9.10',  'while the guests bin is the default' );
    like( exception { Provisioner::IPPool::assign( 'b.test', $pool ) }, qr/pool[ ]exhausted/, 'a full guests bin does not borrow from the clients' );
    is( Provisioner::IPPool::assign( 'b.test', $pool, 'vpnclients' ), '10.8.0.131', 'and the clients bin still has room' );
    like( exception { Provisioner::IPPool::assign( 'c.test', $pool, 'nosuch' ) }, qr/nosuch/, 'and a bin nobody configured is named in the refusal' );

    is_deeply( Provisioner::IPPool::assignments(), { 'a.test' => '10.9.9.10' }, 'only the guests get a record in the zone' );

    is_deeply( Provisioner::IPPool::release('a.test'), { guests => '10.9.9.10', vpnclients => '10.8.0.130' }, 'release gives back the address in each bin' );
    is( Provisioner::IPPool::held_by( 'a.test', 'vpnclients' ), undef, 'and a destroyed domain keeps no client address either' );
};

# A bin with via: the server can give an address out by hand, so it is asked
# before the bin hands out a new one.
my $VIA_POOL = { addresses => '10.9.9.10', bins => { vpnclients => { cidr => '10.8.0.128/29', via => 'vpn.test.test' } } };

# A guest_of that finds the server while $$said is defined, and notes each
# question in @$ran.
sub via_server {
    my ( $said, $ran ) = @_;
    return sub { push( @$ran, "guest_of $_[1]" ); return defined $$said ? bless( {}, 'ViaProbe' ) : undef };
}

subtest 'via_clients: what the server says its clients have' => sub {
    my $said = "laptop.test\t10.8.0.130\nphone\t-\nEND\n";
    my @ran;
    my $fleet = Test::MockModule->new('Trog::Hypervisors');
    $fleet->redefine( guest_of => via_server( \$said, \@ran ) );
    local *ViaProbe::capture_cmd = sub { push( @ran, $_[1] ); return $said };

    is_deeply( { Provisioner::IPPool::via_clients('vpn.test.test') }, { 'laptop.test' => '10.8.0.130' }, 'each client with an address, and not the one whose file has none' );
    like( $ran[-1], qr/\Asudo[ ]-n[ ]sh[ ]-c[ ]/, 'asked as root' );
    cmp_ok( index( $ran[-1], 'openvpn-list-clients --static && echo END' ), '>=', 0, 'with a line that says the command finished' );

    $said = "END\n";
    is_deeply( { Provisioner::IPPool::via_clients('vpn.test.test') }, {}, 'a server with no static client lists none' );

    $said = "laptop.test\t10.8.0.130\n";
    like( exception { Provisioner::IPPool::via_clients('vpn.test.test') }, qr/did[ ]not[ ]say/, 'a list with no END is a command that did not finish' );

    $said = "laptop.test 10.8.0.130\nEND\n";
    like( exception { Provisioner::IPPool::via_clients('vpn.test.test') }, qr/not[ ]a[ ]name,[ ]a[ ]tab[ ]and[ ]an[ ]address/, 'and a line it cannot read is refused' );

    $said = undef;
    like( exception { Provisioner::IPPool::via_clients('vpn.test.test') }, qr/vpn[.]test[.]test[ ]is[ ]not[ ]up/, 'a server that is not up is named' );
};

subtest 'assign: a bin with via does not hand out what its server gave out by hand' => sub {
    fresh_db();
    my $said = "laptop.test\t10.8.0.129\nfar.test\t10.8.1.5\nEND\n";
    my @ran;
    my $fleet = Test::MockModule->new('Trog::Hypervisors');
    $fleet->redefine( guest_of => via_server( \$said, \@ran ) );
    local *ViaProbe::capture_cmd = sub { push( @ran, $_[1] ); return $said };

    is( Provisioner::IPPool::assign( 'a.test', $VIA_POOL, 'vpnclients' ), '10.8.0.130',            'the address of the laptop is skipped' );
    is( Provisioner::IPPool::taken()->{'10.8.0.129'},                     'vpnclient:laptop.test', 'and reserved in its name' );
    ok( !Provisioner::IPPool::taken()->{'10.8.1.5'}, 'while an address outside the bin is not the business of the pool' );
    is( Provisioner::IPPool::assign( 'b.test', $VIA_POOL ), '10.9.9.10', 'and a bin without via asks nobody' );
    is( scalar( grep { m/\Aguest_of/ } @ran ),              1,           'which is one question in all' );

    @ran  = ();
    $said = undef;
    is( Provisioner::IPPool::assign( 'a.test', $VIA_POOL, 'vpnclients' ), '10.8.0.130', 'a domain with an address keeps it while the server is down' );
    is_deeply( \@ran, [], 'without asking the server' );
    like( exception { Provisioner::IPPool::assign( 'c.test', $VIA_POOL, 'vpnclients' ) }, qr/is[ ]not[ ]up/, 'but a new address waits for the server' );
    is( Provisioner::IPPool::held_by( 'c.test', 'vpnclients' ), undef, 'and nothing is written' );

    $said = "c.test\t10.8.0.133\nEND\n";
    is( Provisioner::IPPool::assign( 'c.test', $VIA_POOL, 'vpnclients' ), '10.8.0.133', 'a domain that the server already lists gets that address' );
    ok( !Provisioner::IPPool::taken()->{'10.8.0.129'}, 'and the laptop, which the server no longer lists, gives its address back' );

    $said = "laptop.test\t10.8.0.130\nEND\n";
    my $both = ( exception { Provisioner::IPPool::assign( 'd.test', $VIA_POOL, 'vpnclients' ) } ) // q{};
    cmp_ok( index( $both, 'gives 10.8.0.130 to its VPN client laptop.test, but ips.db gives 10.8.0.130 to a.test' ), '>=', 0, 'two holders of one address stop the assignment, and both are named' ) or diag $both;

    $said = "a.test\t10.8.0.134\nEND\n";
    my $split = ( exception { Provisioner::IPPool::assign( 'd.test', $VIA_POOL, 'vpnclients' ) } ) // q{};
    cmp_ok( index( $split, 'ips.db gives a.test the address 10.8.0.130' ), '>=', 0, 'and so does a domain with one address here and another there' ) or diag $split;
    is( Provisioner::IPPool::held_by( 'd.test', 'vpnclients' ), undef, 'and neither writes anything' );
};

subtest 'refresh_via: the reservations match the server' => sub {
    fresh_db();
    my $said = "laptop.test\t10.8.0.129\nphone.test\t10.8.0.131\nEND\n";
    my @ran;
    my $fleet = Test::MockModule->new('Trog::Hypervisors');
    $fleet->redefine( guest_of => via_server( \$said, \@ran ) );
    local *ViaProbe::capture_cmd = sub { push( @ran, $_[1] ); return $said };

    is( Provisioner::IPPool::refresh_via( $VIA_POOL, 'vpnclients' ), 2, 'both clients are counted' );
    is_deeply( [ @{ Provisioner::IPPool::taken() }{qw{10.8.0.129 10.8.0.131}} ], [qw{vpnclient:laptop.test vpnclient:phone.test}], 'and reserved' );

    $said = "phone.test\t10.8.0.131\nEND\n";
    Provisioner::IPPool::refresh_via( $VIA_POOL, 'vpnclients' );
    ok( !Provisioner::IPPool::taken()->{'10.8.0.129'}, 'a client revoked by hand frees its address' );

    @ran = ();
    is( Provisioner::IPPool::refresh_via( $VIA_POOL, 'guests' ), 0, 'and a bin without via has nothing to ask' );
    is_deeply( \@ran, [], 'so nobody is asked' );
};

subtest 'a database from before bins keeps every row, in the guests bin' => sub {
    fresh_db();

    # The table as it was, with no bin column and one name to one address.
    my $old = Trog::SQLite::dbh( undef, Provisioner::IPPool::db_path() );
    $old->do(q{CREATE TABLE ips (ip TEXT PRIMARY KEY NOT NULL, domain TEXT NOT NULL UNIQUE, kind TEXT NOT NULL DEFAULT 'domain', noted TEXT NOT NULL DEFAULT (datetime('now')))});
    $old->do(q{INSERT INTO ips (ip, domain, kind) VALUES ('10.9.9.10', 'a.test', 'domain'), ('10.9.9.11', 'hv:somewhere', 'reserved')});
    Trog::SQLite::forget();

    my $pool = { addresses => '10.9.9.10 10.9.9.11 10.9.9.12', bins => { vpnclients => { addresses => '10.8.0.130' } } };
    is_deeply( Provisioner::IPPool::assignments(), { 'a.test' => '10.9.9.10' }, 'the guest is still there' );
    is( Provisioner::IPPool::taken()->{'10.9.9.11'},                  'hv:somewhere', 'and so is the reservation' );
    is( Provisioner::IPPool::assign( 'a.test', $pool, 'vpnclients' ), '10.8.0.130',   'and the domain can hold a second address now' );
};

{
    # A stand-in hypervisor, which is also its own libvirt connection.  The
    # sweep is the command that pings, and the other command lists the guests.
    package FakeHV;
    sub new                ( $class, %said ) { return bless {%said}, $class }
    sub manages_addresses  ($self)           { return $self->{cloud} // 0 }
    sub guest_pool         ($self)           { return $self->{pool}  // {} }
    sub configured_gateway ($self)           { return $self->{gateway} }
    sub bridge_device      ($self)           { return $self->{bridge} // die "no bridge\n" }
    sub capture_cmd        ( $self, $cmd )   { return $cmd =~ m/ping/ ? $self->{sweep} : $self->{guests} }
    sub vmm                ($self)           { return $self }

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

# Seeds from one stand-in hypervisor named hv1 with the pool $pool and the
# gateway $gateway, and returns what seed returned.
sub seed_from ( $pool, $gateway, %said ) {
    my $mock = Test::MockModule->new('Trog::Hypervisors');
    $mock->redefine( load => sub { return FakeFleet->new( hv1 => FakeHV->new( pool => $pool, gateway => $gateway, %said ) ) } );
    return Provisioner::IPPool::seed();
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

subtest 'seed: each hypervisor is seeded from its own pool, with its own gateway' => sub {
    fresh_db();

    # Two networks.  A guest of hv2 that reports an address on the network of
    # hv1 is not on that network, so the address of hv1 stays free.
    my %common = ( bridge => 'br0', sweep => q{} );
    my $mock   = Test::MockModule->new('Trog::Hypervisors');
    $mock->redefine(
        load => sub {
            return FakeFleet->new(
                hv1   => FakeHV->new( %common, pool => { cidr => ['192.0.2.0/28'] },    gateway => '192.0.2.1',    names => ['one.test'], guests => "one.test\t192.0.2.5\n" ),
                hv2   => FakeHV->new( %common, pool => { cidr => ['198.51.100.0/28'] }, gateway => '198.51.100.1', names => ['two.test'], guests => "two.test\t198.51.100.5\ntwo.test\t192.0.2.6\n" ),
                cloud => FakeHV->new( cloud => 1, gateway => '203.0.113.1' ),
            );
        }
    );
    Provisioner::IPPool::seed();

    is_deeply(
        Provisioner::IPPool::taken(),
        { '192.0.2.1' => 'gateway:192.0.2.1', '192.0.2.5' => 'one.test', '198.51.100.1' => 'gateway:198.51.100.1', '198.51.100.5' => 'two.test' },
        'each gateway is reserved and each guest recorded in the pool of its own hypervisor, and a cloud adds nothing'
    );
};

subtest 'pool_of: the pool of a guest is the pool of its hypervisor and the bins of _global' => sub {
    my %bins = ( vpnclients => { cidr => '10.8.0.128/25', via => 'vpn.test' } );
    is_deeply( Provisioner::IPPool::pool_of( FakeHV->new( pool => { cidr => ['192.0.2.0/28'] } ),             { bins => \%bins } ), { cidr => ['192.0.2.0/28'], bins => \%bins }, 'the guests bin at the top, beside the other bins' );
    is_deeply( Provisioner::IPPool::pool_of( FakeHV->new( cloud => 1, pool => { cidr => ['192.0.2.0/28'] } ), { bins => \%bins } ), { bins => \%bins },                           'and no guests bin on a hypervisor that gives its guests their addresses' );
    is_deeply( Provisioner::IPPool::pool_of( FakeHV->new(),                                                   undef ),              { bins => {} },                               'and nothing at all when nothing names a pool' );
};

subtest 'guest_pools: two networks cannot share an address' => sub {
    my $fleet = sub (%pools) {
        return FakeFleet->new( map { $_ => FakeHV->new( pool => $pools{$_} ) } keys %pools );
    };

    my %one = ( cidr => ['192.0.2.0/28'] );
    is_deeply( { Provisioner::IPPool::guest_pools( $fleet->( hv1 => {%one}, hv2 => {%one}, hv3 => {} ) ) }, { hv1 => \%one, hv2 => \%one }, 'two hypervisors on one network share its pool, and one with none is left out' );
    is_deeply( { Provisioner::IPPool::guest_pools( $fleet->( hv1 => {%one}, hv2 => { cidr => ['192.0.2.16/28'] } ) ) }, { hv1 => \%one, hv2 => { cidr => ['192.0.2.16/28'] } }, 'and two networks that do not overlap have one each' );

    my $err = ( exception { Provisioner::IPPool::guest_pools( $fleet->( hv1 => {%one}, hv2 => { addresses => ['192.0.2.9'] } ) ) } ) // q{};
    like( $err, qr/hv1 .* 192[.]0[.]2[.]0\/28/, 'an address inside the pool of another network is refused, naming the one block' );
    like( $err, qr/hv2 .* 192[.]0[.]2[.]9\/32/, 'and the other' );
    like( $err, qr/which[ ]overlap/,            'and saying why' );
    like(
        exception { Provisioner::IPPool::guest_pools( $fleet->( hv1 => {%one}, hv2 => {%one}, hv3 => { cidr => ['192.0.2.0/24'] } ) ) },
        qr/pool[ ]of[ ]hv1,[ ]hv2[ ]/,
        'and a pool that holds the pool of a shared network is refused, naming every hypervisor on that network'
    );
    like( exception { Provisioner::IPPool::guest_pools( $fleet->( hv1 => { cidr => ['192.0.2.0/33'] } ) ) }, qr/Invalid[ ]CIDR .* hv1/, 'and so is a block that is not one, by its hypervisor' );
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

    like( exception { Provisioner::IPPool::pool_ips( { cidr => '2001:db8::/126' } ) }, qr/not[ ]IPv4/, 'an IPv6 block is refused rather than counted as integers' );

    my @wide = Provisioner::IPPool::pool_ips( { cidr => '10.16.0.0/20' } );
    is_deeply [ @wide[ 0, 1, -1 ] ], [qw{10.16.0.1 10.16.0.2 10.16.15.254}], 'a block wider than a /24 carries across the octets';
    is( scalar @wide, 4094, 'and holds each of its hosts once' );
};

subtest 'address_to_int and int_to_address: an address and its integer' => sub {
    my %pairs = ( '0.0.0.0' => 0, '0.0.1.0' => 256, '10.8.0.129' => 168296577, '255.255.255.255' => 4294967295 );
    foreach my $address ( sort keys %pairs ) {
        is( Provisioner::IPPool::address_to_int($address),           $pairs{$address}, "$address is $pairs{$address}" );
        is( Provisioner::IPPool::int_to_address( $pairs{$address} ), $address,         "and $pairs{$address} is $address" );
    }

    foreach my $bad ( qw{256.0.0.1 10.8.0 localhost}, q{}, undef ) {
        my $shown = $bad // 'undef';
        like( exception { Provisioner::IPPool::address_to_int($bad) }, qr/is[ ]not[ ]an[ ]IPv4[ ]address\n\z/, "'$shown' is not an address, and no name is resolved" );
    }

    # pack N wraps a number outside the range, so 2**32 would be 0.0.0.0.
    foreach my $bad ( -1, 4294967296, 1.5, 'ten', undef ) {
        my $shown = $bad // 'undef';
        like( exception { Provisioner::IPPool::int_to_address($bad) }, qr/is[ ]not[ ]an[ ]IPv4[ ]address[ ]as[ ]an[ ]integer/, "$shown is refused" );
    }
};

done_testing;
