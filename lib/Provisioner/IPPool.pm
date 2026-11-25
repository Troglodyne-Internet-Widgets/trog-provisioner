package Provisioner::IPPool;

#ABSTRACT: Assign static IP addresses from a pool, and record which are taken.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';
no autovivification;

use DBI();
use DBD::SQLite::Constants qw{SQLITE_OPEN_READONLY};
use List::Util             qw{first uniq};
use Net::CIDR();
use Net::IP();
use Socket();

use Provisioner::Cookbook();
use Provisioner::IPPool::DB();
use Provisioner::IPPool::Remote();
use Provisioner::Utils();

use Trog::Config();
use Trog::Hypervisors();
use Trog::Utils();

=head1 NAME

Provisioner::IPPool - assign static IP addresses from a pool, and record which are taken

=head1 SYNOPSIS

    use Provisioner::IPPool;

    # Only the scripts in bin/ use this interface.
    my $pool_block = { addresses => '10.0.0.5 10.0.0.6', cidr => '10.0.1.0/29' };

    my @ips = Provisioner::IPPool::pool_ips($pool_block);
    my $ip  = Provisioner::IPPool::assign( 'test.test', $pool_block );

    # The pools of the guests of one hypervisor, with the bins of _global.
    my $pool  = Provisioner::IPPool::pool_of( $hv, $globals->{ip_pool} );
    my $ip    = Provisioner::IPPool::assign( 'test.test', $pool );
    my $other = Provisioner::IPPool::assign( 'test.test', $pool, undef, 'br0' );

The addresses of the C<guests> bin are on the subnets of the bridges of the
static adapters of a guest, C<static_nics>, and the block of the hypervisor
names a pool for each one.  See L<Trog::HV/nic_pool($nic)>.  F<docs/NETWORK.md>
says what that means.

=head1 BINS

A bin is a named part of the pool.  Each bin hands out only its own addresses,
so one kind of client cannot use up the addresses of another.  The bin named
C<guests> is where a guest gets its addresses, one on the bridge of each of its
static adapters.  Each one is on the network of a hypervisor, so the block of
that hypervisor names it, and C<pool_of> puts them under C<nics> in the pool,
by bridge.  The pool of the first of C<static_nics>, which gives the address
of the guest, is also at the top of the pool, as C<addresses> and C<cidr>.  The
C<bins> of the C<ip_pool> of C<_global> name the others:

    ip_pool:
        bins:
            lab:
                cidr: 10.9.0.0/28

A domain holds at most one address in each bin, and in the C<guests> bin one on
each bridge.  The database records the bridge of each address of the C<guests>
bin, and which one is the address of the guest, the one on the first of
C<static_nics>.  Only that one goes into C<assignments>, so a guest gets an A
record from it and from nothing else.

A bin that names a guest in C<via> holds addresses that only that guest can
reach, such as the static addresses of the clients of a VPN:

    ip_pool:
        bins:
            vpnclients:
                cidr: 10.8.0.128/25
                via: vpn.test.test

Every other guest gets a route to the networks of the bin through the address of
C<via>, and the firewall of C<via> lets them in.  The addresses themselves are
not in any database: C<via> gives them out, and it is the only record of them.
L<Provisioner::Recipe::openvpn> gives each client of the bin the first free
address of the bin, or the one that the client already has, and
L<Provisioner::Recipe::openvpnclient> asks for one with C<issue_from>.  So
C<assign> refuses such a bin, and C<main_addresses> and the subs that read it
ask C<via> for the address of a client, with C<via_clients>, and die when it
cannot be asked.

=head1 WHY A DATABASE

Two runs cannot safely share a file of assignments.  Both read it, both find the
same free address, and both write it.  The second write wins.  Two guests then
get the same address, and nothing reports an error.  You find out later, when
you cannot connect to one of them.

So the assignments are in SQLite, and each assignment is one transaction.  The
row goes in, or the address is already taken and C<assign> tries the next one.
The configuration still gives the range of the pool.

=head1 ONE DATABASE FOR EACH HYPERVISOR

SQLite keeps two writers apart through a file that each one maps into memory,
and that works only on one machine, not between two runners that mount the
configuration directory of their hypervisor.  So each libvirt hypervisor keeps
its own database, at the C<ip_db> of its block, see
L<Trog::HV::Libvirt/ip_db>, and only processes on that hypervisor open it.
Every operation runs there, in one process, through F<bin/ippool>: in this
process when the hypervisor is this machine, and otherwise over ssh, see
L<Provisioner::IPPool::Remote>.  The SQL is in L<Provisioner::IPPool::DB>.

The subs below keep the interface that they had.  Which database each one
asks:

=over 4

=item * An address of the C<guests> bin is kept by the hypervisor whose pool of
that bridge it is in: the pool of the bridge, as C<pool_of> gives it, names
the network, and the network names the hypervisor.  No two hypervisors may
name overlapping pools, see C<guest_pools>.  A pool that names no network of
the fleet goes to the only database, and is refused when there is more than
one.

=item * An address of another bin without C<via> belongs to no hypervisor, so
it goes to the only database, and is refused when there is more than one.

=item * A read of the whole fleet, such as C<taken> or C<assignments>, asks
every hypervisor that keeps a database, and merges what they say.  It dies,
naming the hypervisor, when one does not answer, or when two disagree about
one address.  It never returns part of the fleet.  C<release> and C<reseed>
also go to each of them.

=item * Without F<hypervisors.conf>, the database is the F<ips.db> of the
configuration directory of this machine, as it was before.  A fleet with no
libvirt hypervisor has no database at all.

=back

C<release> and C<reseed> are each one transaction in each database, and not
one across the fleet.  A hypervisor that fails partway leaves the databases
before it changed and those after it as they were, and a second run finishes
the work.


=head1 MIGRATION

To move from the one F<ips.db> of the configuration directory to a database
for each hypervisor, with nothing provisioning anywhere:

=over 4

=item 1. Install what the kit needs on each libvirt hypervisor that has a pool,
L<Provisioner::IPPool::Remote/What the far side needs>, and see that it runs:

    bin/ippool --hypervisor=hv1 check

=item 2. Choose a path for its database on that hypervisor, which only the
hypervisor writes, and which each account that provisions there can write.
Name it as C<ip_db> in the block of the hypervisor in F<hypervisors.conf>.

=item 3. Make the database:

    bin/ippool --hypervisor=hv1 init

=item 4. Copy the rows that belong to it out of the old database, first as a
dry run.  The rows of a bin with C<via> stay behind, because its server is the
record of them.  Name with C<--bin> each other bin of C<_global> that this
hypervisor is to keep, unless the fleet has one hypervisor that keeps a
database:

    bin/ippool --hypervisor=hv1 migrate --from=/etc/trog-provisioner/ips.db --dryrun
    bin/ippool --hypervisor=hv1 migrate --from=/etc/trog-provisioner/ips.db

=item 5. Ask the hypervisors what runs, which fills in what the old database
missed and makes the reservations again:

    bin/reseed_ips --dryrun
    bin/reseed_ips

=item 6. Move the old F<ips.db> and its F<-wal> and F<-shm> out of the
configuration directory, so that nothing opens it again.

=back

=head1 SUBROUTINES

=head2 $GUESTS

The name of the bin that a guest gets its address from: C<guests>.

=cut

our $GUESTS = 'guests';

=head2 pool_ips($pool)

C<$pool> is one bin, as a hash reference, such as the pool of one bridge that
L<Trog::HV/nic_pool($nic)> returns.
C<addresses> is a list of addresses, each of which may carry the length of the
prefix of its network, such as C<10.0.0.5/26>, and C<cidr> is a list of CIDR
blocks.  Either may be written as a YAML list or as one string with whitespace
between the items.

Returns each address in the pool once, in order.  Dies if a CIDR block is not
valid, or is not IPv4.

=over 4

=item pool - HashRef - one bin, with C<addresses> and C<cidr>

=back

    my \@ips = Provisioner::IPPool::pool_ips( { cidr => '192.0.2.0/29', addresses => '198.51.100.7' } );

=cut

sub pool_ips {
    my ($pool) = @_;
    my ( %seen, @ips );

    foreach my $ip ( addresses_of($pool) ) {
        push @ips, $ip unless $seen{$ip}++;
    }

    foreach my $cidr ( pool_items( $pool->{cidr} ) ) {
        my $net = Net::IP->new($cidr)
          or die "Invalid CIDR '$cidr': " . Net::IP::Error() . "\n";
        die "The CIDR block '$cidr' is not IPv4, and the pool holds IPv4 addresses only\n"
          unless $net->version == 4;

        # Integers rather than ++ on the Net::IP object, which costs about a
        # millisecond for each address.
        my ( $first, $last ) = map { address_to_int($_) } $net->ip, $net->last_ip;
        my @block = map { int_to_address($_) } $first .. $last;

        # The first address of an IPv4 block is the network and the last is
        # the broadcast.  A guest on either one cannot talk to anything.
        # A /31 is a point-to-point link with two usable addresses (RFC 3021).
        # A /32 is one host.  Neither block has an address to spare.
        if ( @block > 2 ) {
            pop @block;
            shift @block;
        }

        foreach my $ip (@block) {
            push @ips, $ip unless $seen{$ip}++;
        }
    }

    return @ips;
}

=head2 address_to_int($address)

Returns the IPv4 address C<$address> as an integer, so that a range of
addresses is a range of integers.  Dies if C<$address> is not an IPv4 address.
It does not resolve a name.

=over 4

=item address - Str - the address

=back

    my $int = Provisioner::IPPool::address_to_int('192.0.2.1');    # 3221225985

=cut

sub address_to_int {
    my ($address) = @_;
    my $packed = Socket::inet_pton( Socket::AF_INET(), $address // q{} ) // die "'" . ( $address // 'undef' ) . "' is not an IPv4 address\n";
    return unpack( 'N', $packed );
}

=head2 int_to_address($int)

Returns the integer C<$int> as an IPv4 address.  Dies if C<$int> is not an
integer from 0 to 4294967295.

=over 4

=item int - Int - the integer

=back

    my $address = Provisioner::IPPool::int_to_address(3221225985);    # '192.0.2.1'

=cut

sub int_to_address {
    my ($int) = @_;
    return Socket::inet_ntoa( pack( 'N', $int ) ) if defined $int && $int =~ m{\A\d+\z} && $int <= 0xFFFFFFFF;
    die "'" . ( $int // 'undef' ) . "' is not an IPv4 address as an integer\n";
}

=head2 db_path()

Returns the path of the database of this machine: F<ips.db>, in the same
directory as the rest of the configuration.  It is the database when no fleet
is configured, and the one of a hypervisor that is this machine and names no
C<ip_db>.  The callers name it in a message about a missing address.

Takes no arguments.

    my $path = Provisioner::IPPool::db_path();

=cut

sub db_path { return Trog::Config->path('ips.db') }

=head2 $databases = databases($fleet)

Where the addresses of the L<Trog::Hypervisors> C<$fleet> are kept, by default
the fleet of F<hypervisors.conf>.  A hash reference of:

=over 4

=item * C<list>: each database, once, in the order of the blocks.  A database
is a hash reference of C<name>, the block of the hypervisor, C<hv>, the
hypervisor, C<path>, the path of F<ips.db> there, and C<create>, true for the
database of the configuration directory of this machine, which the first use
makes.  Without a fleet, the one database is that one, with no C<hv>.

=item * C<of>: the database of each hypervisor that keeps one, by name.  Two
blocks for one machine and one path share it.

=item * C<network>: the database that keeps the addresses of the pool of each
bridge, by the bridge, a tab and the network of its pool, as C<network_of>
gives it.  No two pools overlap, see C<guest_pools>, so each network has one.

=item * C<pools>: what C<guest_pools> returns.

=item * C<configured>: whether there is a fleet.

=back

A libvirt hypervisor keeps a database when its block names C<ip_db>, or when it
is this machine.  Dies when a remote one has a pool for a static adapter and
names no C<ip_db>, because its guests then have nowhere to get an address, and
as C<guest_pools> does.  It builds the hypervisors, and connects to none.

=over 4

=item fleet - Trog::Hypervisors - optional: the fleet

=back

Returns HashRef, as above.

    my $databases = Provisioner::IPPool::databases();

=cut

sub databases ( $fleet = undef ) {
    $fleet //= Trog::Hypervisors->load( Trog::Hypervisors->default_path() );
    return { configured => 0, list => [ { name => 'local', path => db_path(), create => 1 } ], of => {}, network => {}, pools => {} } unless $fleet->configured;

    my %pools = guest_pools($fleet);
    my ( @list, %of, %at, %network );
    foreach my $name ( $fleet->names ) {
        my $hv = $fleet->hypervisor($name);
        next if $hv->manages_addresses;

        my $path   = $hv->ip_db;
        my $create = !defined $path;
        $path //= db_path() if $hv->is_local;
        unless ( defined $path ) {
            next unless $pools{$name};
            die "[$name] in hypervisors.conf has a pool for its static adapters, and no ip_db.  Each hypervisor keeps its own address database, at the ip_db of its block.\n" . "See MIGRATION in Provisioner::IPPool.\n";
        }

        my $where = $hv->is_local ? "here:$path" : $hv->describe . ":$path";
        $of{$name} = $at{$where} //= do {
            push @list, { name => $name, hv => $hv, path => $path, create => $create };
            $list[-1];
        };
        for my $key ( keys %{ $pools{$name} // {} } ) { $network{ "$key\t" . network_of( $pools{$name}{$key} ) } = $of{$name}; }
    }

    return { configured => 1, list => \@list, of => \%of, network => \%network, pools => \%pools };
}

=head2 $result = call($database, $op, $args)

Runs the operation C<$op> of L<Provisioner::IPPool::DB> with the hash
reference C<$args> on C<$database>, one of the C<list> of C<databases>, and
returns its result.  It runs in this process when the hypervisor is this
machine, and otherwise on the hypervisor, through
L<Provisioner::IPPool::Remote/call($machine, $path, $op, $args, %opts)>.
Dies as the operation does, or when the hypervisor cannot be asked.

=over 4

=item database - HashRef - one of the C<list> of C<databases>

=item op - Str - the name of the operation

=item args - HashRef - optional: the arguments of the operation, empty by default

=back

Returns Any, the result of the operation.

    my $taken = Provisioner::IPPool::call( Provisioner::IPPool::databases()->{list}[0], 'taken' );

=cut

sub call ( $database, $op, $args = {} ) {
    my $hv = $database->{hv};
    return Provisioner::IPPool::DB::run( $database->{path}, $op, $args, create => $database->{create} ) if !$hv || $hv->is_local;
    return Provisioner::IPPool::Remote::call( $hv, $database->{path}, $op, $args, create => $database->{create} );
}

=head2 $result = on_hypervisor($name, $op, $args)

C<call> on the database of the hypervisor C<$name>, for F<bin/ippool>.  Dies
when that hypervisor keeps none.

=over 4

=item name - Str - the block of the hypervisor, or undef when only one keeps a database

=item op - Str - the name of the operation

=item args - HashRef - optional: the arguments of the operation, empty by default

=back

Returns Any, the result of the operation.  Dies also when C<$name> is undef and
more than one hypervisor keeps a database.

    my $taken = Provisioner::IPPool::on_hypervisor( 'hv1', 'taken' );

=cut

# The database of the hypervisor $name in $databases, or the only database
# when $name is undef.
my sub database_of ( $databases, $name ) {
    if ( defined $name ) {
        return $databases->{of}{$name} // die "$name keeps no address database: it is not a libvirt hypervisor in hypervisors.conf with an ip_db, or this machine.\n";
    }
    return $databases->{list}[0] if @{ $databases->{list} } == 1;
    die 'More than one hypervisor keeps addresses (' . join( ', ', map { $_->{name} } @{ $databases->{list} } ) . "), so name the one that this is for.\n";
}

sub on_hypervisor ( $name, $op, $args = {} ) {
    return call( database_of( databases(), $name ), $op, $args );
}

# What each database says $op is for $args, merged into one hash reference.
# Dies when two databases give one key two values, because then one address
# has two holders, or one domain two addresses.
my sub merged ( $op, $args = {} ) {
    my ( %all, %from );
    foreach my $database ( @{ databases()->{list} } ) {
        my $said = call( $database, $op, $args );
        foreach my $key ( sort keys %$said ) {
            my $value = $said->{$key} // q{};
            die "The address databases disagree: $from{$key} says that $key is $all{$key}, and $database->{name} says $value.\n"
              if exists $all{$key} && $all{$key} ne $value;
            $all{$key}  = $value;
            $from{$key} = $database->{name};
        }
    }
    return \%all;
}

=head2 assignments()

Returns a hash reference of each guest domain to the address of the guest: its
address in the C<guests> bin on the first of its C<static_nics>.  Reservations,
the other bridges and the other bins are not in it.  C<bin/new_config> gives
this to the templates as the C<ipmap> variable, which is the address of each
domain rather than a file, and the pdns zone makes its records from it.

Takes no arguments.  Dies when two databases disagree about a domain.

    my $ipmap = Provisioner::IPPool::assignments();

=cut

sub assignments { return merged('assignments') }

=head2 ($guest, $address) = guest_address($domain)

The guest that runs C<$domain>, which is C<host_of> it in
L<Provisioner::Cookbook> or the domain itself, and the address of that guest in
C<assignments>.  The address is undef when the guest has none, so that the
caller can say what needed it.

=over 4

=item domain - Str - the domain

=back

Returns a list of two: Str, the guest, and Str or undef, its address.

    my ( $guest, $address ) = Provisioner::IPPool::guest_address('web.test.test');

=cut

sub guest_address {
    my ($domain) = @_;
    my $guest = Provisioner::Cookbook->machine_of($domain);
    return ( $guest, assignments()->{$guest} );
}

=head2 taken()

Returns a hash reference of each address in the database to the name that holds
it.  Reservations are in it, because a reserved address is not free.

Takes no arguments.  Dies when two databases disagree about an address.

    my $taken = Provisioner::IPPool::taken();

=cut

sub taken { return merged('taken') }

=head2 held_by($domain, $bin, $nic)

Returns the address that C<$domain> has in C<$bin>, or undef.  C<$bin> defaults
to C<guests>.  In the C<guests> bin, it is the address on the bridge C<$nic>,
or without C<$nic> the address of the guest.

It looks at guests only.  A reservation is not a domain, and C<release> must
never report that it gave back the gateway.

It asks every database, and dies when two of them give the domain an address
in the bin.

=over 4

=item domain - Str - the domain

=item bin - Str - optional: the bin

=item nic - Str - optional: the bridge

=back

    my $ip = Provisioner::IPPool::held_by( 'web.test.test', 'guests', 'br0' );

=cut

sub held_by {
    my ( $domain, $bin, $nic ) = @_;
    my %args = ( domain => $domain, bin => $bin // $GUESTS, ( defined $nic ? ( nic => $nic ) : () ) );
    my @held = uniq grep { defined } map { call( $_, 'held_by', \%args ) } @{ databases()->{list} };
    die "The address databases give $domain more than one address in the bin $args{bin}: @held\n" if @held > 1;
    return $held[0];
}

=head2 main_addresses($domain)

Returns a hash reference of each bin in which C<$domain> has an address, to
its main address there: in the C<guests> bin, the address of the guest, on the
first of its C<static_nics>, and not the addresses on its other bridges.  It is
empty when the domain has none.  Like C<held_by>, it looks at domains only, not
at reservations.  The address of a client of a VPN is in it as
C<client_addresses> gives it, so it dies as that does.

=over 4

=item domain - Str - the domain

=back

    my $by_bin = Provisioner::IPPool::main_addresses('web.test.test');

=cut

sub main_addresses {
    my ($domain) = @_;
    return { %{ merged( 'main_addresses', { domain => $domain } ) }, %{ client_addresses($domain) } };
}

=head2 client_addresses($domain)

Returns the static address of C<$domain> as a client of a VPN, as a hash
reference of the bin with C<via> to that address.  The server C<via> gives it,
and it is the only record of it, so this asks it, with C<via_clients>.  Empty,
and nobody is asked, when the C<openvpnclient> of the domain names no
C<issue_from>, or C<ip_pool> has no bin whose C<via> is that server.  Empty
also when the server gives the domain no address in the bin.  Dies when the
server cannot be asked.

=over 4

=item domain - Str - the domain

=back

    my $by_bin = Provisioner::IPPool::client_addresses('laptop.test.test');

=cut

sub client_addresses {
    my ($domain) = @_;
    my $via      = ( Provisioner::Cookbook->domain_config($domain)->{openvpnclient}   // {} )->{issue_from} // return {};
    my %bins     = bins_via( Provisioner::Cookbook->global_config($domain)->{ip_pool} // {}, $via );
    return {} unless %bins;

    my %clients = via_clients($via);
    my $address = $clients{$domain} // return {};
    my ($bin)   = grep { local ($_) = $_; Net::CIDR::cidrlookup( $address, blocks( $bins{$_} ) ) } sort keys %bins;
    return defined $bin ? { $bin => $address } : {};
}

=head2 nic_addresses($domain)

Returns a hash reference of each bridge on which C<$domain> has an address in
the C<guests> bin, to that address, the main one among them.  An address from
before the database recorded bridges is not in it until C<assign> gives it its
bridge.

=over 4

=item domain - Str - the domain

=back

    my $by_nic = Provisioner::IPPool::nic_addresses('web.test.test');

=cut

sub nic_addresses {
    my ($domain) = @_;
    return merged( 'nic_addresses', { domain => $domain } );
}

=head2 reachable_address($domain)

Returns the address at which the other guests reach the guest of C<$domain>:
its address in a bin other than C<guests>, which is the tunnel of a guest that
is a client of the VPN, and otherwise its address in C<guests>.  Dies when it
has neither, or more than one of the first kind.

=over 4

=item domain - Str - the domain

=back

    my $address = Provisioner::IPPool::reachable_address('web.test.test');

=cut

# The bin of the tunnel of $domain among the bins that it $held, or undef.
my sub tunnel_bin ( $domain, $held ) {
    my @vpn = grep { $_ ne $GUESTS } sort keys %$held;
    die "$domain has an address in each of " . join( ', ', @vpn ) . ", so the guests that use it cannot tell which one reaches it.\n" if @vpn > 1;
    return $vpn[0];
}

sub reachable_address {
    my ($domain) = @_;
    my $held     = main_addresses($domain);
    my $tunnel   = tunnel_bin( $domain, $held );

    my $address = $held->{ $tunnel // $GUESTS };
    die "$domain has no address in the address databases or on a VPN server, so the guests that use it cannot reach it.\n" unless defined $address;
    return $address;
}

=head2 $guest = reached_through($domain, $pool)

The guest that routes the address of C<reachable_address> to the other guests:
the C<via> of the bin of that address in C<$pool>.  The other guests reach
C<$domain> only on the network of that guest, see L<Trog::HV/network>.  Undef
when C<$domain> has no address in a bin with a C<via>, because then the other
guests reach it on its own network.  Dies as C<reachable_address> does when
C<$domain> has an address in two tunnels.

=over 4

=item domain - Str - the domain

=item pool - HashRef - the pool, as C<pool_of> returns it

=back

Returns Str or undef: the guest.

    my $router = Provisioner::IPPool::reached_through( 'laptop.test.test', $pool );

=cut

sub reached_through {
    my ( $domain, $pool ) = @_;
    my $tunnel = tunnel_bin( $domain, main_addresses($domain) ) // return undef;
    my %bins   = bins($pool);
    return $bins{$tunnel} ? $bins{$tunnel}{via} : undef;
}

=head2 release($domain)

Gives back every address of C<$domain>, in every bin and on every bridge.

Returns HashRef[Str], what it gave back: each bin to its address, as
C<main_addresses> gives it, and of C<guests on NIC> to the address on each bridge
that is not the address of the guest.

C<bin/destroy> calls this, and C<bin/reseed_ips> calls it for a domain that no
hypervisor runs.  A domain that you provision again keeps its address.

It gives them back in every database, one after another.  A hypervisor that
cannot be asked stops it there, and a second run gives back the rest.

=over 4

=item domain - Str - the domain

=back

Dies when two databases disagree, or when a hypervisor cannot be asked.

    my $freed = Provisioner::IPPool::release('web.test.test');

=cut

sub release {
    my ($domain) = @_;
    return merged( 'release', { domain => $domain } );
}

=head2 @items = pool_items($said)

Returns the items of one key of an C<ip_pool>, such as C<addresses> or C<cidr>.
C<$said> is a list, or one string with whitespace between the items, or undef.

=over 4

=item said - Str|ArrayRef[Str]|Undef - the items

=back

    my \@items = Provisioner::IPPool::pool_items('192.0.2.0/29 198.51.100.0/30');

=cut

sub pool_items {
    my ($said) = @_;
    return grep { m/\S/ } map { split /\s+/ } @{ Provisioner::Utils::coerce_arrayref( $said // [] ) };
}

=head2 %bins = bins($pool)

Returns each bin of C<$pool> by name, as a block that C<pool_ips> takes.  The
C<addresses> and C<cidr> at the top of C<$pool> are the bin named C<guests>.

Dies if C<$pool> has addresses at its top and also a bin named C<guests>, if a
block of a bin is not valid, or if blocks of two bins overlap.  The pools of
the other bridges under C<nics> count as bins of their own for that, because an
address belongs to one bridge.

=over 4

=item pool - HashRef - the pool

=back

    my %bins = Provisioner::IPPool::bins($pool);

=cut

sub bins {
    my ($pool) = @_;

    my %bins = %{ $pool->{bins} // {} };
    my %top  = map { $_ => $pool->{$_} } grep { defined $pool->{$_} } qw{addresses cidr};
    if (%top) {
        die "The addresses at the top of ip_pool are the bin named $GUESTS, so ip_pool cannot also have a bin named $GUESTS\n"
          if $bins{$GUESTS};
        $bins{$GUESTS} = \%top;
    }

    my %others = map { ( "$GUESTS on $_" => $pool->{nics}{$_} ) } grep { $_ ne ( $pool->{first_nic} // q{} ) } keys %{ $pool->{nics} // {} };
    my %check  = ( %bins, %others );
    my @seen;
    foreach my $name ( sort keys %check ) {
        foreach my $block ( blocks( $check{$name} ) ) {
            Net::IP->new($block)
              or die "Invalid CIDR '$block' in the bin $name of ip_pool: " . Net::IP::Error() . "\n";
            my ($other) = grep { local ($_) = $_; $_->{bin} ne $name && Net::CIDR::cidrlookup( $block, $_->{block} ) } @seen;
            die "ip_pool has $block in the bin $name and $other->{block} in the bin $other->{bin}, which overlap, and an address can belong to one bin only\n"
              if $other;
            push @seen, { bin => $name, block => $block };
        }
    }

    return %bins;
}

=head2 %bins = bins_via($pool, $guest)

Returns each bin of C<$pool> whose C<via> is C<$guest>, by name, as C<bins>
does.  Such a bin holds addresses that C<$guest> routes to, such as the static
addresses of the clients of an openvpn server, and every other guest reaches
them through C<$guest>.  Empty when no bin names C<$guest>.

=over 4

=item pool - HashRef - the pool

=item guest - Str - the domain of the guest

=back

Dies as C<bins> does.

    my %bins = Provisioner::IPPool::bins_via( $pool, 'vpn.test.test' );

=cut

sub bins_via {
    my ( $pool, $guest ) = @_;

    my %bins = bins($pool);
    return map { $_ => $bins{$_} } grep { defined $bins{$_}{via} && $bins{$_}{via} eq $guest } keys %bins;
}

=head2 $pool = pool_of($hv, $installation_pool)

Returns the pool that a guest of the hypervisor C<$hv> takes its addresses
from: the pool of each of its C<static_nics> under C<nics>, by bridge, as
L<Trog::HV/static_pools> gives them, the first of them as C<first_nic>, its
pool also at the top as C<addresses> and C<cidr>, which is the C<guests> bin,
and the C<bins> of C<$installation_pool>, the C<ip_pool> of C<_global>.  A
hypervisor that gives its guests their addresses has no C<guests> bin here,
because its guests take none from the pool.

=over 4

=item hv - Trog::HV - the hypervisor

=item installation_pool - HashRef - optional: the C<ip_pool> of C<_global>

=back

Returns HashRef, the pool.

    my $pool = Provisioner::IPPool::pool_of( $hv, $global{ip_pool} );

=cut

sub pool_of {
    my ( $hv, $installation_pool ) = @_;
    my %bins = ( bins => { %{ ( $installation_pool // {} )->{bins} // {} } } );
    return \%bins if $hv->manages_addresses;

    my $nics  = $hv->static_pools;
    my $first = $hv->address_nic;
    return { %bins, nics => $nics, ( defined $first ? ( first_nic => $first, %{ $nics->{$first} } ) : () ) };
}

=head2 $network = network_of($pool)

The blocks of the bin C<$pool>, as C<blocks> gives them, sorted and joined
into one string.  Two hypervisors on one network name the same blocks, so their
pools have the same answer here.

=over 4

=item pool - HashRef - one bin

=back

Returns Str, the network.

    my $network = Provisioner::IPPool::network_of( { cidr => '192.0.2.0/29' } );    # '192.0.2.0/29'

=cut

sub network_of {
    my ($pool) = @_;
    return join( q{ }, sort( blocks($pool) ) );
}

=head2 %pools = guest_pools($fleet)

Returns the pools of the static adapters of each hypervisor of the
L<Trog::Hypervisors> C<$fleet> that names any, by the name of its block, each a
hash reference of the bridge to its pool, as L<Trog::HV/static_pools> returns
it.  A hypervisor that gives its guests their addresses is left out.

Dies when the pools of two bridges overlap, of one hypervisor or of two, and
names both and their blocks.  On one hypervisor, an address belongs to one
bridge.  Two hypervisors each keep the addresses of their pools in a database
of their own, so two of them that name one range, even the same blocks on a
bridge of the same name, would both give out its addresses.  Give each
hypervisor its own part of such a network.

=over 4

=item fleet - Trog::Hypervisors - the fleet

=back

    my %pools = Provisioner::IPPool::guest_pools($fleet);

=cut

sub guest_pools {
    my ($fleet) = @_;

    my %pools;
    foreach my $name ( $fleet->configured ? $fleet->names : () ) {
        my $hv = $fleet->hypervisor($name);
        next if $hv->manages_addresses;
        my $nics = $hv->static_pools;
        foreach my $nic ( sort keys %$nics ) {
            for my $item ( blocks( $nics->{$nic} ) ) { Net::IP->new($item) // die "Invalid CIDR '$item' in ip_pool_$nic of $name in hypervisors.conf: " . Net::IP::Error() . "\n"; }
        }
        $pools{$name} = $nics if %$nics;
    }

    # One claim for each block of the pool of each bridge of each hypervisor.
    my @claims;
    foreach my $name ( sort keys %pools ) {
        foreach my $nic ( sort keys %{ $pools{$name} } ) {
            push @claims, map { +{ block => $_, names => "$nic of $name" } } blocks( $pools{$name}{$nic} );
        }
    }
    foreach my $claim (@claims) {
        my ($other) = grep { local ($_) = $_; $_->{names} ne $claim->{names} && Net::CIDR::cidrlookup( $claim->{block}, $_->{block} ) } @claims or next;
        die "The pool of $claim->{names} in hypervisors.conf has $claim->{block} and the pool of $other->{names} has $other->{block}, which overlap.\n" . "Each hypervisor keeps the addresses of its pools in its own database, so no two pools may overlap, not even the same blocks on two hypervisors.\n";
    }

    return %pools;
}

=head2 @blocks = blocks($bin)

Returns the networks of C<$bin>, a block that C<pool_ips> takes, as CIDR
blocks: each C<cidr> as it is, then each of its C<addresses> as a C</32>.

=over 4

=item bin - HashRef - one bin

=back

    my \@blocks = Provisioner::IPPool::blocks( { addresses => '192.0.2.7' } );    # ( '192.0.2.7/32' )

=cut

sub blocks {
    my ($bin) = @_;
    return ( pool_items( $bin->{cidr} ), map { "$_/32" } addresses_of($bin) );
}

=head2 @addresses = addresses_of($bin)

The C<addresses> of C<$bin>, without the length of a prefix that one is written
with.

=over 4

=item bin - HashRef - one bin

=back

Returns a list of Str, the addresses.

    my \@addresses = Provisioner::IPPool::addresses_of( { addresses => '192.0.2.7/26' } );    # ( '192.0.2.7' )

=cut

sub addresses_of {
    my ($bin) = @_;
    return map { s{/\d+\z}{}r } pool_items( $bin->{addresses} );
}

=head2 %clients = via_clients($via)

Asks the guest C<$via>, the openvpn server of a bin, which static address each
of its clients has.  Returns each name of a client to its address.  It runs the
C<static_clients_command> of L<Provisioner::Recipe::openvpn> there as root.
The server is the only record of these addresses: see L</BINS>.

Dies if C<$via> is not up, or if the command does not finish, or if it prints
a line that is not a name and an address.

=over 4

=item via - Str - the domain of the server

=back

Returns a list of pairs of Str.

    my %clients = Provisioner::IPPool::via_clients('vpn.test.test');

=cut

sub via_clients {
    my ($via) = @_;

    my $command = Provisioner::Cookbook->load('openvpn')->static_clients_command();
    my $guest   = Trog::Hypervisors->guest_of($via)
      or die "$via is not up, so it cannot say which addresses its VPN clients have, and it is the only record of them.  Start $via, and try again.\n";

    # capture_cmd gives no exit status, so the last line says that the
    # command finished.  The stderr goes, because sudo runs the command in a
    # pty that carries it along with stdout.
    my $said = $guest->capture_sudo( qw{sh -c}, "exec 2>/dev/null; $command && echo END" ) // q{};
    die "$via did not say which addresses its VPN clients have.  Run $command there to see why.\n"
      unless $said =~ s/^END\n?\z//m;

    my %clients;
    foreach my $line ( split /\n/, $said ) {
        my ( $name, $address ) = $line =~ m/\A(\S+)\t(\S+)\z/
          or die "$via listed '$line' as a VPN client, which is not a name, a tab and an address\n";

        # A ccd file with no ifconfig-push gives the client no address.
        $clients{$name} = $address unless $address eq '-';
    }
    return %clients;
}

=head2 $bool = offers($pool, $bin)

Whether C<$bin> of C<$pool> has an address to give out, free or not.  C<$bin>
defaults to C<guests>, which is the pool of the first static adapter.  False
for a pool that names no addresses and no blocks, and for a pool that has none
at all.

A guest of a hypervisor with no static adapter, so whose C<guests> bin offers
nothing, gets no address from the pool.  It takes a lease on the NAT network of
its hypervisor.  That is the case of a runner that builds throwaway guests,
which nothing outside the hypervisor has to reach.  So the callers ask this,
and not C<assign>, which dies on such a bin.

=over 4

=item pool - HashRef - the pool

=item bin - Str - optional: the bin

=back

Returns Bool, 1 or 0.  Dies as C<bins> does.

    my $static = Provisioner::IPPool::offers($pool);

=cut

sub offers {
    my ( $pool, $bin ) = @_;

    my %bins   = bins( $pool                      // {} );
    my @blocks = blocks( $bins{ $bin // $GUESTS } // {} );
    return @blocks ? 1 : 0;
}

=head2 assign($domain, $pool, $bin, $nic)

Returns the address of C<$domain> in C<$bin> of C<$pool>.  C<$bin> defaults to
C<guests>.  If the domain has no address there, this gives it the first free
address of that bin.  If it has one, this returns that address.

In the C<guests> bin, the address is on the bridge C<$nic>, out of its pool in
C<nics>, and C<$nic> defaults to C<first_nic>, whose address is the address of
the guest.  The row records the bridge, and whether it is that address, which
this writes again when the order of C<static_nics> changed.  A domain whose
address dates from before the database recorded bridges keeps it: the first
time it asks for an address on the bridge whose pool holds that address, the
row gets the bridge.  A pool without C<nics>, such as one that a test or a
script makes, is one bridge with no name.

The address is chosen and written in the database that keeps the bin, see
L</ONE DATABASE FOR EACH HYPERVISOR>, by one operation of F<bin/ippool> on
that hypervisor, in one transaction: see
L<Provisioner::IPPool::DB/assign>.  The transaction takes the write lock
before it looks for a free address, so if two provisions run at the same time,
the second waits, searches again, and finds the address taken.

Dies if the bin has no addresses, or if no address in it is free.  Dies for a
bin with C<via>, whose server gives out its addresses: see L</BINS>.

=over 4

=item domain - Str - the domain

=item pool - HashRef - the pool, as C<pool_of> returns it

=item bin - Str - optional: the bin

=item nic - Str - optional: the bridge

=back

Returns Str, the address.

    my $ip = Provisioner::IPPool::assign( 'web.test.test', $pool );

=cut

sub assign {
    my ( $domain, $pool, $bin, $nic ) = @_;
    $bin //= $GUESTS;

    my $first = $pool->{first_nic};
    my $guest = $bin eq $GUESTS;
    $nic = $guest ? $nic // $first // q{} : q{};
    my $main = !$guest || !defined $first || $nic eq $first ? 1 : 0;

    my %bins = bins($pool);
    my $conf = $guest && $nic ne q{} && $pool->{nics} ? $pool->{nics}{$nic} : $bins{$bin};
    die "The bin $bin of the pool routes through $conf->{via}, which gives out its addresses itself, so there is none to assign to $domain here.  See BINS in Provisioner::IPPool.\n"
      if defined $conf->{via};

    my @pool_ips = pool_ips( $conf // {} );
    die "No [ip_pool] section or no IPs found in the $bin bin of the pool" . ( $nic ne q{} ? " on $nic" : q{} ) . ": cannot auto-assign IP for $domain\n"
      unless @pool_ips;

    # A pool that names no network of the fleet, such as one that a test or a
    # script makes, goes to the only database.
    my $databases = databases();
    my $database  = $databases->{network}{ "$nic\t" . network_of($conf) } // database_of( $databases, undef );

    return call( $database, 'assign', { domain => $domain, bin => $bin, nic => $nic, main => $main, guest => $guest ? 1 : 0, candidates => \@pool_ips } );
}

=head2 ensure_seeded()

Fills the databases from the addresses that are already in use, once for each
hypervisor.  Returns what C<seed> returns.

Each entry point can call this.  It skips each hypervisor that it seeded before,
so it asks no hypervisor twice.

Dies if it cannot connect to a hypervisor.  A database with half the fleet
in it gives out addresses that guests already use.  The seed does not mark that
hypervisor as done, so the next run tries it again.

Takes no arguments.

Returns Int, the number of addresses recorded.

    Provisioner::IPPool::ensure_seeded();

=cut

sub ensure_seeded {
    return seed();
}

# What the hypervisor $hv, the block $name, uses on the bridges of $nics, its
# pools by bridge, as the rows of a seed of Provisioner::IPPool::DB: its
# gateways, and with $sweep, its guests, itself and the other machines that
# answer.  It asks the hypervisor, and writes nothing.
my sub discover ( $hv, $name, $nics, $sweep ) {

    # The bridge whose pool holds each address.  The pools of one hypervisor
    # do not overlap: see guest_pools.
    my %nic_of;
    foreach my $nic ( sort keys %$nics ) {
        $nic_of{$_} = $nic foreach pool_ips( $nics->{$nic} );
    }
    my $first = $hv->address_nic;
    my @rows;

    # Each gateway goes first, so that its row names it as the gateway and
    # not as one more machine that answered.
    foreach my $nic ( sort keys %$nics ) {
        my $gateway = $hv->nic_gateway($nic);
        push @rows, [ 'reserve', $gateway, "gateway:$gateway", $nic ] if defined $gateway && ( $nic_of{$gateway} // q{} ) eq $nic;
    }

    # Once per hypervisor.  The marker is written only after the hypervisor
    # answers everything, so a failure is retried.
    return @rows unless $sweep;

    # The sweep goes first, because it fills the neighbor table.  libvirt
    # knows the bridged address of a guest only if the host spoke to it
    # lately.  It runs on the hypervisor, because this machine can be on a
    # different network.
    my $swept = q{};
    foreach my $nic ( sort keys %$nics ) {

        # An answer to the ping is the main signal.  A REACHABLE entry in
        # the table is a second one, and the table also gives the hardware
        # address.  REACHABLE alone is not reliable: an entry can decay to
        # STALE before the read.
        #
        # Do not quote each address.  They are numbers, and a quote inside
        # the script closes the quoting of the sh -c around it.
        #
        # No sudo.  Any user may ping and read the neighbor table, and the
        # account of a runner has no grant for either.
        my @mine   = grep { $nic_of{$_} eq $nic } sort keys %nic_of;
        my $script = join q{ }, map { "(ping -c1 -W1 $_ >/dev/null 2>&1 && echo LIVE $_) &" } grep { m/\A\d+(?:[.]\d+){3}\z/ } @mine;
        $script .= " wait; ip -4 neigh show dev $nic";
        $swept  .= ( $hv->capture_cmd( qw{sh -c}, $script ) // q{} ) . "\n";
    }

    # STALE is not a signal.  It outlives the machine, so reserving it
    # leaks the pool.
    my %mac  = $swept =~ m/^(\d+(?:[.]\d+){3})\h+lladdr\h+(\S+)/mg;
    my %live = map { $_ => 1 } ( $swept =~ m/^LIVE\h+(\d+(?:[.]\d+){3})$/mg ), ( $swept =~ m/^(\d+(?:[.]\d+){3})\h+lladdr\h+\S+\N*\bREACHABLE\b/mg );

    # The address of each guest comes from its provision.conf.  libvirt
    # knows that a guest exists, but not the address it was built with,
    # and the neighbor table misses a quiet guest and keeps the address of
    # a destroyed one.  No eval, on purpose: see ensure_seeded.
    my @names = %nic_of ? map { local ($_) = $_; $_->get_name() } $hv->vmm->list_all_domains() : ();
    if (@names) {
        my $dir    = $hv->domain_dir;
        my $script = join "\n", map {
            my ( $q, $conf ) = map { Trog::Utils::shell_quote($_) } $_, "$dir/$_/provision.conf";
            "printf '%s\\t%s\\n' $q \"\$(grep -oE '^[[:space:]]*ips[[:space:]]*=[[:space:]]*[0-9.]+' $conf 2>/dev/null | grep -oE '[0-9.]+' | head -1)\""
        } @names;

        # Also ask libvirt for the address of each guest.  This finds a
        # guest whose provision.conf is missing or cannot be read, and the
        # addresses of its other static adapters.
        #
        # This runs virsh on the hypervisor, not Sys::Virt from here.  The
        # ARP source reads the neighbor table of the client.  This machine
        # is not on the bridge of the guests, so from here it reports only
        # the NAT address.
        #
        # virsh asks the daemon that list_all_domains asked, by -c, because
        # without it the login user asks its own session; see local_uri.
        my $virsh = join q{ }, 'virsh', map { Trog::Utils::shell_quote($_) } $hv->local_connect;
        $script .= "\n" . join "\n", map {
            my $q = Trog::Utils::shell_quote($_);
            "$virsh domifaddr $q --source arp 2>/dev/null | grep -oE '[0-9]+(\\.[0-9]+){3}' | sed -e \"s|^|$_\t|\"";
        } @names;

        # No sudo.  A provision.conf belongs to the user that ran
        # new_config, who is usually the login user.  A file that the login
        # user cannot read is the case above, which virsh covers.  virsh
        # needs only the access that list_all_domains has.
        my $said = $hv->capture_cmd( qw{sh -c}, $script ) // q{};

        # A guest also answers on the NAT bridge, and libvirt gives out
        # those addresses, not this pool.
        my @found = $said =~ m/^([^\t\n]+)\t(\d+(?:[.]\d+){3})$/mg;
        while ( my ( $domain, $ip ) = splice( @found, 0, 2 ) ) {
            my $nic = $nic_of{$ip} // next;
            push @rows, [ 'record', $ip, $domain, $nic, $nic eq ( $first // q{} ) ? 1 : 0 ];
        }
    }

    # The hypervisor goes before the machines that answered, so that its row
    # names it.  Its address comes from the host part of its libvirt URI.
    # If that name does not resolve, nothing is reserved for it.
    my $host   = eval { $hv->ssh_host };
    my $packed = $host   && Socket::inet_aton($host);
    my $ip     = $packed && Socket::inet_ntoa($packed);
    push @rows, [ 'reserve', $ip, "hv:$name", $nic_of{$ip} ] if $ip && $nic_of{$ip};

    # Other machines that answer, for example a printer or a router.  An
    # address in a pool that answers and that no guest holds belongs to
    # some other machine, so it is reserved.  The database ignores the
    # reservation of an address that a guest holds.
    push @rows, map { [ 'reserve', $_, 'insitu:' . ( $mac{$_} // 'unknown' ), $nic_of{$_} ] } grep { $nic_of{$_} } sort keys %live;

    return @rows;
}

=head2 seed()

Records the address of each guest on each hypervisor.  It also reserves the
addresses of the hypervisors, their gateways, and other machines that answer.
Returns the number of addresses it recorded.  The pool and the gateway of each
static adapter come from the block of its hypervisor, see C<guest_pools> and
L<Trog::HV/nic_gateway($nic)>, and it dies as C<guest_pools> does.  Each row
records the bridge whose pool holds the address, and goes into the database of
that hypervisor.

The list of guests comes from the hypervisors, not from the configuration.  A
hypervisor reports what it runs, but somebody can edit a file.  The address
of each guest comes from its own F<provision.conf>, which is what it was built
with.

It records an address only when it is in a pool of the hypervisor that runs the
guest.  C<assign> cannot give out an address outside the pools, so a row for one
is noise.  The address in F<provision.conf> is the address of the guest, on the
first of C<static_nics>.

Another machine that answers is an address in the pool that answers a ping from
the hypervisor, or that the neighbor table of its bridge holds as C<REACHABLE>,
and that no guest holds.  Its name is C<insitu:> and its hardware address, or
C<unknown> if the table has none.  An entry that is out of date reserves an
address that is free.  That is the safe error, because the other error gives
out an address that is in use.  Each bridge of C<static_nics> is swept.

What it found on one hypervisor goes into its database in one operation, so a
hypervisor that does not answer, or a database that cannot be written, leaves
that hypervisor unmarked, and the next seed asks it again.

Takes no arguments.

Returns Int, the number.  Dies also when a hypervisor cannot be asked.

    my $recorded = Provisioner::IPPool::seed();

=cut

sub seed {
    my $fleet     = Trog::Hypervisors->load( Trog::Hypervisors->default_path() );
    my $databases = databases($fleet);

    my $recorded = 0;
    foreach my $name ( sort keys %{ $databases->{pools} } ) {
        my $database = $databases->{of}{$name};
        my %seeded   = map { $_ => 1 } @{ call( $database, 'seeded' ) };
        my $done     = $seeded{"hv:$name"};
        my @rows     = discover( $fleet->hypervisor($name), $name, $databases->{pools}{$name}, !$done );

        $recorded += call( $database, 'seed', { rows => \@rows, mark => $done ? [] : ["hv:$name"] } );
    }

    return $recorded;
}

=head2 $result = reseed(%opts)

What F<bin/reseed_ips> does: asks each hypervisor what it uses, and then, in
one transaction in each database, forgets which hypervisors were seeded,
deletes each reservation and writes what the hypervisors said.  With
C<prune>, it also releases each domain that no hypervisor of the fleet runs.
With C<dryrun>, each database rolls its transaction back.

Every hypervisor is asked before any database is written, so a hypervisor that
does not answer changes nothing.  A database that fails leaves the ones before
it reseeded: see L</ONE DATABASE FOR EACH HYPERVISOR>.

Returns a hash reference of C<before> and C<after>, what C<taken> says before
and after, C<on> and C<on_after>, each address of a guest to its bridge, before
and after, and C<pruned>, the number of domains released.  Dies with C<prune>
and no fleet, because then nothing can say which guests run, and every
assignment would go.

=over 4

=item prune - Bool - optional: release each domain that no hypervisor runs

=item dryrun - Bool - optional: roll each transaction back

=back

Dies also when a hypervisor cannot be asked.

    my $result = Provisioner::IPPool::reseed( dryrun => 1 );

=cut

sub reseed (%opts) {
    my $fleet     = Trog::Hypervisors->load( Trog::Hypervisors->default_path() );
    my $databases = databases($fleet);

    my @running;
    if ( $opts{prune} ) {
        die "--prune needs hypervisors.conf: with no fleet, nothing can say which guests are running, and every assignment would be released.\n"
          unless $fleet->configured;
        @running = uniq sort map { local ($_) = $_; $fleet->hypervisor($_)->guest_names } $fleet->names;
    }

    my %seeds;
    foreach my $name ( sort keys %{ $databases->{pools} } ) {
        my @rows = discover( $fleet->hypervisor($name), $name, $databases->{pools}{$name}, 1 );
        push @{ $seeds{ $databases->{of}{$name}{name} } }, { rows => \@rows, mark => ["hv:$name"] };
    }

    my %out = ( ( map { $_ => {} } qw{before after on on_after} ), pruned => 0 );
    foreach my $database ( @{ $databases->{list} } ) {
        my $said = call( $database, 'reseed', { seeds => $seeds{ $database->{name} } // [], ( $opts{prune} ? ( prune => \@running ) : () ), dryrun => $opts{dryrun} ? 1 : 0 } );
        $out{$_} = { %{ $out{$_} }, %{ $said->{$_} } } foreach qw{before after on on_after};
        $out{pruned} += $said->{pruned};
    }
    return \%out;
}

=head2 $result = migrate($name, $from, %opts)

Copies the rows that belong to the hypervisor C<$name> out of the database at
C<$from> on this machine, the one F<ips.db> from before each hypervisor kept
its own, into the database of C<$name>, with the C<migrate> of
L<Provisioner::IPPool::DB>.  It opens C<$from> read only.

A row belongs to C<$name> when it is in the C<guests> bin, an address or a
reservation, on a network of a pool of C<$name>, or when its bin is one of the
array reference C<bins> in C<%opts>.  When only one hypervisor keeps a
database, every row belongs to it.  A row of a bin with C<via> in the
C<ip_pool> of the C<_global> of C<_base> belongs to no database, because the
server of the bin is the record of it: see L</BINS>.  It does not copy which
hypervisors were seeded, so the next seed asks each one again.  With
C<dryrun>, it writes nothing.

Returns C<added>, C<kept> and C<skipped>, the numbers of rows written, already
there, and left behind.  Dies as that operation does, and when C<$from> cannot
be read.

=over 4

=item name - Str - the block of the hypervisor

=item from - Str - the path of the old database

=item bins - ArrayRef[Str] - optional: more bins that belong to C<$name>

=item dryrun - Bool - optional: write nothing

=back

    my $result = Provisioner::IPPool::migrate( 'hv1', '/bogus/old-ips.db', dryrun => 1 );

=cut

sub migrate ( $name, $from, %opts ) {
    my $databases = databases();
    my $database  = database_of( $databases, $name );
    my $pools     = $databases->{pools};

    my @blocks = map {
        my $hv = $_;
        map { blocks( $pools->{$hv}{$_} ) } sort keys %{ $pools->{$hv} }
    } grep { $databases->{of}{$_} == $database } sort keys %$pools;
    my %named  = map { $_ => 1 } @{ $opts{bins} // [] };
    my %served = bins( Provisioner::Cookbook->base_global()->{ip_pool} // {} );
    my $every  = @{ $databases->{list} } == 1;

    my $rows = eval {
        my $old = DBI->connect( "dbi:SQLite:dbname=$from", q{}, q{}, { RaiseError => 1, PrintError => 0, sqlite_open_flags => SQLITE_OPEN_READONLY } );
        $old->selectall_arrayref( 'SELECT ip, domain, kind, bin, nic, main, assigned_at FROM ips ORDER BY ip', { Slice => {} } );
    } or die "Could not read the addresses of $from: $@";

    my @mine = grep { local ($_) = $_; !defined( ( $served{ $_->{bin} } // {} )->{via} ) && ( $every || $named{ $_->{bin} } || ( $_->{bin} eq $GUESTS && @blocks && Net::CIDR::cidrlookup( $_->{ip}, @blocks ) ) ) } @$rows;
    my $said = call( $database, 'migrate', { rows => \@mine, dryrun => $opts{dryrun} ? 1 : 0 } );
    return { %$said, skipped => @$rows - @mine };
}

1;
