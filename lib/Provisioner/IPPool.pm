package Provisioner::IPPool;

#ABSTRACT: Assign static IP addresses from a pool, and record which are taken.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Cwd();
use File::Basename();
use List::Util qw{first};
use Net::IP;
use Socket();

use Provisioner::Cookbook();
use Provisioner::Utils();

use Trog::Config();
use Trog::SQLite();
use Trog::Hypervisors();

=head1 NAME

Provisioner::IPPool - assign static IP addresses from a pool, and record which are taken

=head1 SYNOPSIS

    use Provisioner::IPPool;

    # Only the scripts in bin/ use this interface.
    my $pool_block = { addresses => '10.0.0.5 10.0.0.6', cidr => '10.0.1.0/29' };

    my @ips = Provisioner::IPPool::pool_ips($pool_block);
    my $ip  = Provisioner::IPPool::assign( 'test.test', $pool_block );

    # A pool with a second bin, for the clients of a VPN.
    my $pool = { cidr => '192.0.2.0/24', bins => { vpnclients => { cidr => '10.8.0.128/25' } } };
    my $vpn  = Provisioner::IPPool::assign( 'test.test', $pool, 'vpnclients' );

The addresses of the C<guests> bin are on the subnet of the primary bridge of the
hypervisor.  F<docs/NETWORK.md> says what that means.

=head1 BINS

A bin is a named part of the pool.  Each bin hands out only its own addresses,
so one kind of client cannot use up the addresses of another.  The
C<addresses> and C<cidr> at the top of C<ip_pool> are the bin named C<guests>,
which is where a guest gets its address.  C<bins> names the others:

    ip_pool:
        cidr: 192.0.2.0/24
        bins:
            vpnclients:
                cidr: 10.8.0.128/25

A domain holds at most one address in each bin.  Only the C<guests> bin goes
into C<assignments>, so only a guest gets an A record from it.

A bin that names a guest in C<via> holds addresses that only that guest can
reach, such as the static addresses of the clients of a VPN:

    ip_pool:
        cidr: 192.0.2.0/24
        bins:
            vpnclients:
                cidr: 10.8.0.128/25
                via: vpn.test.test

Every other guest gets a route to the networks of the bin through the address of
C<via>.  L<Provisioner::Recipe::openvpn> gives each client in the bin its
address, and L<Provisioner::Recipe::openvpnclient> takes one with
C<issue_from>.

The server of such a bin can also give an address to a client by hand, and
then only the server knows it.  So before C<assign> hands out a new address
from the bin, it asks C<via> which addresses its clients have, with
C<via_clients>.  It reserves each address that the database does not know, as
C<vpnclient:> and the name of the client, and it deletes the reservation of an
address that the server no longer gives out.  When C<via> cannot be asked,
C<assign> dies rather than guess.

=head1 WHY A DATABASE

Two runs cannot safely share a file of assignments.  Both read it, both find the
same free address, and both write it.  The second write wins.  Two guests then
get the same address, and nothing reports an error.  You find out later, when
you cannot connect to one of them.

So the assignments are in SQLite, and each assignment is one transaction.  The
row goes in, or the address is already taken and C<assign> tries the next one.
The C<ip_pool> of the C<_global> of C<_base> still gives the range of the pool.

=head1 SUBROUTINES

=head2 $GUESTS

The name of the bin that a guest gets its address from: C<guests>.

=cut

our $GUESTS = 'guests';

=head2 pool_ips($pool)

C<$pool> is the C<ip_pool> of the C<_global> of C<_base>, as a hash reference,
which L<Provisioner::Cookbook/globals> hands back with the rest of them.
C<addresses> is a list of addresses and C<cidr> is a list of CIDR blocks.
Either may be written as a YAML list or as one string with whitespace between
the items.

Returns each address in the pool once, in order.  Dies if a CIDR block is not
valid, or is not IPv4.

=cut

sub pool_ips {
    my ($pool) = @_;
    my ( %seen, @ips );

    foreach my $ip ( pool_items( $pool->{addresses} ) ) {
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

=cut

sub address_to_int {
    my ($address) = @_;
    my $packed = Socket::inet_pton( Socket::AF_INET(), $address // q{} ) // die "'" . ( $address // 'undef' ) . "' is not an IPv4 address\n";
    return unpack( 'N', $packed );
}

=head2 int_to_address($int)

Returns the integer C<$int> as an IPv4 address.  Dies if C<$int> is not an
integer from 0 to 4294967295.

=cut

sub int_to_address {
    my ($int) = @_;
    return Socket::inet_ntoa( pack( 'N', $int ) ) if defined $int && $int =~ m{\A\d+\z} && $int <= 0xFFFFFFFF;
    die "'" . ( $int // 'undef' ) . "' is not an IPv4 address as an integer\n";
}

=head2 db_path()

Returns the path of the database.  This is F<ips.db>, in the same directory as
the rest of the configuration.

=cut

sub db_path { return Trog::Config->path('ips.db') }

=head2 schema_path()

Returns the absolute path of F<schema/ips.sql> in this checkout.  The path is
relative to this file, as C<bin/new_config> finds its scripts.

=cut

sub schema_path {
    return Cwd::abs_path( File::Basename::dirname(__FILE__) . '/../../schema/ips.sql' );
}

=head2 dbh()

Returns a handle on the database at C<db_path>, with the schema and its updates
applied.  F<schema/ips.v1.update.sql> adds bins, and puts every row of a
database from before them in the C<guests> bin.

=cut

sub dbh { return Trog::SQLite::dbh( schema_path(), db_path() ) }

=head2 assignments()

Returns a hash reference of each guest domain to its address in the C<guests>
bin.  Reservations and the other bins are not in it.  C<bin/new_config> gives
this to the templates as the C<ipmap> variable, which is the address of each
domain rather than a file, and the pdns zone makes its records from it.

=cut

sub assignments {
    my $rows = dbh()->selectall_arrayref( "SELECT domain, ip FROM ips WHERE kind = 'domain' AND bin = ?", { Slice => {} }, $GUESTS );
    return { map { $_->{domain} => $_->{ip} } @$rows };
}

=head2 ($guest, $address) = guest_address($domain)

The guest that runs C<$domain>, which is C<host_of> it in
L<Provisioner::Cookbook> or the domain itself, and the address of that guest in
C<assignments>.  The address is undef when the guest has none, so that the
caller can say what needed it.

=cut

sub guest_address {
    my ($domain) = @_;
    my $guest = Provisioner::Cookbook->machine_of($domain);
    return ( $guest, assignments()->{$guest} );
}

=head2 taken()

Returns a hash reference of each address in the database to the name that holds
it.  Reservations are in it, because a reserved address is not free.

=cut

sub taken {
    my $rows = dbh()->selectall_arrayref( 'SELECT ip, domain FROM ips', { Slice => {} } );
    return { map { $_->{ip} => $_->{domain} } @$rows };
}

=head2 held_by($domain, $bin)

Returns the address that C<$domain> has in C<$bin>, or undef.  C<$bin> defaults
to C<guests>.

It looks at guests only.  A reservation is not a domain, and C<release> must
never report that it gave back the gateway.

=cut

sub held_by {
    my ( $domain, $bin ) = @_;
    my $row = dbh()->selectrow_arrayref( "SELECT ip FROM ips WHERE domain = ? AND kind = 'domain' AND bin = ?", undef, $domain, $bin // $GUESTS );
    return $row ? $row->[0] : undef;
}

=head2 holdings($domain)

Returns a hash reference of each bin in which C<$domain> has an address, to
that address.  It is empty when the domain has none.  Like C<held_by>, it looks
at domains only, not at reservations.

=cut

sub holdings {
    my ($domain) = @_;
    my $rows = dbh()->selectall_arrayref( "SELECT bin, ip FROM ips WHERE domain = ? AND kind = 'domain'", { Slice => {} }, $domain );
    return { map { $_->{bin} => $_->{ip} } @$rows };
}

=head2 reachable_address($domain)

Returns the address at which the other guests reach the guest of C<$domain>:
its address in a bin other than C<guests>, which is the tunnel of a guest that
is a client of the VPN, and otherwise its address in C<guests>.  Dies when it
has neither, or more than one of the first kind.

=cut

sub reachable_address {
    my ($domain) = @_;
    my $held     = holdings($domain);
    my @vpn      = grep { $_ ne $GUESTS } sort keys %$held;

    die "$domain has an address in each of " . join( ', ', @vpn ) . ", so the guests that use it cannot tell which one reaches it.\n" if @vpn > 1;
    my $address = @vpn ? $held->{ $vpn[0] } : $held->{$GUESTS};
    die "$domain has no address in " . db_path() . ", so the guests that use it cannot reach it.\n" unless defined $address;
    return $address;
}

=head2 reserve($ip, $name)

Records C<$ip> as an address that no guest gets, for example a hypervisor or a
gateway.  C<$name> says what holds it.  Returns true if this call wrote the row.

An address that is already in the database is not an error.  Seeding runs on
every start, and it records the same addresses each time.

=cut

sub reserve {
    my ( $ip, $name ) = @_;
    my $rows = dbh()->do( "INSERT OR IGNORE INTO ips (ip, domain, kind) VALUES (?, ?, 'reserved')", undef, $ip, $name );
    return $rows && $rows != 0 ? 1 : 0;
}

=head2 record($ip, $domain)

Records C<$ip> as the address of the guest C<$domain>.  This is for an address
that a hypervisor reports, not one that C<assign> gave out.  Returns true if
this call wrote the row.

=cut

sub record {
    my ( $ip, $domain ) = @_;
    my $rows = dbh()->do( "INSERT OR IGNORE INTO ips (ip, domain, kind) VALUES (?, ?, 'domain')", undef, $ip, $domain );
    return $rows && $rows != 0 ? 1 : 0;
}

=head2 release($domain)

Gives back every address of C<$domain>, in every bin.  Returns what it gave
back, as C<holdings> does: a hash reference of each bin to its address.

C<bin/destroy> calls this, and C<bin/reseed_ips> calls it for a domain that no
hypervisor runs.  A domain that you provision again keeps its address.

=cut

sub release {
    my ($domain) = @_;

    my $db   = dbh();
    my $held = holdings($domain);
    $db->do( "DELETE FROM ips WHERE domain = ? AND kind = 'domain'", undef, $domain );

    return $held;
}

=head2 @items = pool_items($said)

Returns the items of one key of an C<ip_pool>, such as C<addresses> or C<cidr>.
C<$said> is a list, or one string with whitespace between the items, or undef.

=cut

sub pool_items {
    my ($said) = @_;
    return grep { m/\S/ } map { split /\s+/ } @{ Provisioner::Utils::coerce_arrayref( $said // [] ) };
}

=head2 %bins = bins($pool)

Returns each bin of C<$pool> by name, as a block that C<pool_ips> takes.  The
C<addresses> and C<cidr> at the top of C<$pool> are the bin named C<guests>.

Dies if C<$pool> has addresses at its top and also a bin named C<guests>, if a
block of a bin is not valid, or if blocks of two bins overlap.

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

    my @seen;
    foreach my $name ( sort keys %bins ) {
        foreach my $block ( blocks( $bins{$name} ) ) {
            my $net = Net::IP->new($block)
              or die "Invalid CIDR '$block' in the bin $name of ip_pool: " . Net::IP::Error() . "\n";
            foreach my $other ( grep { $_->{bin} ne $name } @seen ) {
                my $overlap = $net->overlaps( $other->{net} ) // $IP_NO_OVERLAP;
                die "ip_pool has $block in the bin $name and $other->{block} in the bin $other->{bin}, which overlap, and an address can belong to one bin only\n"
                  if $overlap != $IP_NO_OVERLAP;
            }
            push @seen, { bin => $name, block => $block, net => $net };
        }
    }

    return %bins;
}

=head2 %bins = bins_via($pool, $guest)

Returns each bin of C<$pool> whose C<via> is C<$guest>, by name, as C<bins>
does.  Such a bin holds addresses that C<$guest> routes to, such as the static
addresses of the clients of an openvpn server, and every other guest reaches
them through C<$guest>.  Empty when no bin names C<$guest>.

=cut

sub bins_via {
    my ( $pool, $guest ) = @_;

    my %bins = bins($pool);
    return map { $_ => $bins{$_} } grep { defined $bins{$_}{via} && $bins{$_}{via} eq $guest } keys %bins;
}

=head2 @blocks = blocks($bin)

Returns the networks of C<$bin>, a block that C<pool_ips> takes, as CIDR
blocks: each C<cidr> as it is, then each of its C<addresses> as a C</32>.

=cut

sub blocks {
    my ($bin) = @_;
    return ( pool_items( $bin->{cidr} ), map { "$_/32" } pool_items( $bin->{addresses} ) );
}

=head2 %clients = via_clients($via)

Asks the guest C<$via>, the openvpn server of a bin, which static address each
of its clients has.  Returns each name of a client to its address.  It runs the
C<static_clients_command> of L<Provisioner::Recipe::openvpn> there as root.

Dies if C<$via> is not up, or if the command does not finish, or if it prints
a line that is not a name and an address.

=cut

sub via_clients {
    my ($via) = @_;

    my $command = Provisioner::Cookbook->load('openvpn')->static_clients_command();
    my $guest   = Trog::Hypervisors->guest_of($via)
      or die "$via is not up, so it cannot say which addresses its VPN clients have, and an address from its bin could be one that it already gave out.  Start $via, and try again.\n";

    # capture_cmd gives no exit status, so the last line says that the
    # command finished.  The stderr goes, because sudo runs the command in a
    # pty that carries it along with stdout.
    ( my $quoted = "exec 2>/dev/null; $command && echo END" ) =~ s/'/'\\''/g;
    my $said = $guest->capture_cmd("sudo -n sh -c '$quoted'") // q{};
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

# Makes the reservations of the clients that the via of the bin $bin, as $conf,
# lists match what it said, in the transaction of the caller.  $for is a domain
# that is about to get its address, which the server may already list.
my sub note_clients {
    my ( $db, $bin, $conf, $clients, $for ) = @_;
    my $via    = $conf->{via};
    my %in_bin = map { $_ => 1 } pool_ips($conf);

    $db->do( "DELETE FROM ips WHERE kind = 'reserved' AND bin = ? AND domain LIKE 'vpnclient:%'", undef, $bin );
    my %holder = map { $_->[0] => $_->[1] } @{ $db->selectall_arrayref( 'SELECT ip, domain FROM ips WHERE bin = ?', undef, $bin ) };
    my %has    = reverse %holder;

    foreach my $name ( sort keys %$clients ) {
        my $address = $clients->{$name};
        next unless $in_bin{$address};

        my $holder = $holder{$address};
        next if defined $holder && $holder eq $name;
        die "$via gives $address to its VPN client $name, but ips.db gives $address to $holder.  Revoke one of them on $via, or release it.\n"
          if defined $holder;
        die "$via gives $address to its VPN client $name, but ips.db gives $name the address $has{$name}.  Revoke $name on $via, and build it again.\n"
          if defined $has{$name};
        next if defined $for && $name eq $for;

        $db->do( "INSERT INTO ips (ip, domain, kind, bin) VALUES (?, ?, 'reserved', ?)", undef, $address, "vpnclient:$name", $bin );
    }
    return;
}

=head2 refresh_via($pool, $bin)

Asks the C<via> of C<$bin> which addresses its clients have, with
C<via_clients>, and makes the C<vpnclient:> reservations of the bin match what
it said.  C<bin/list_ip_pool> runs it, so that the list shows the addresses
that were given out by hand.  Returns the number of clients that the server
listed, or 0 when the bin has no C<via>.

Dies as C<via_clients> does, or if what the server says disagrees with the
database: an address of a domain that the server gives to another client, or a
domain that has one address in the database and another on the server.

=cut

sub refresh_via {
    my ( $pool, $bin ) = @_;

    my %bins    = bins($pool);
    my $via     = ( $bins{$bin} // {} )->{via} // return 0;
    my %clients = via_clients($via);

    my $db = dbh();
    $db->do('BEGIN IMMEDIATE');
    my $ok = eval {
        note_clients( $db, $bin, $bins{$bin}, \%clients );
        $db->do('COMMIT');
        1;
    };
    if ( !$ok ) {
        my $err = $@ || "Could not note the VPN clients of $via\n";
        eval { $db->do('ROLLBACK') };    ## no critic (ErrorHandling::RequireCheckingReturnValueOfEval) -- report $err, not a failed rollback after it
        die $err;
    }

    return scalar keys %clients;
}

=head2 $bool = offers($pool, $bin)

Whether C<$bin> of C<$pool> has an address to give out, free or not.  C<$bin>
defaults to C<guests>.  False for a pool that names no addresses and no blocks,
and for a pool that has none at all.

A guest of a configuration whose C<guests> bin offers nothing gets no address
from the pool.  It takes a lease on the NAT network of its hypervisor, and its
bridged interface stays unconfigured.  That is the case of a runner that builds
throwaway guests, which nothing outside the hypervisor has to reach.  So the
callers ask this, and not C<assign>, which dies on such a bin.

=cut

sub offers {
    my ( $pool, $bin ) = @_;

    my %bins   = bins( $pool                      // {} );
    my @blocks = blocks( $bins{ $bin // $GUESTS } // {} );
    return @blocks ? 1 : 0;
}

=head2 assign($domain, $pool, $bin)

Returns the address of C<$domain> in C<$bin> of C<$pool>.  C<$bin> defaults to
C<guests>.  If the domain has no address there, this gives it the first free
address of that bin.  If it has one, this returns that address and writes
nothing.

For a bin with C<via>, a domain with no address there gets one only after the
server is asked, as L</BINS> says.  If the server already gives the domain an
address in the bin, the domain gets that one.  A domain that has an address
gets it without the question, so the rebuild of a client does not need the
server.

Dies if the bin has no addresses, or if no address in it is free.  For a bin
with C<via>, it also dies as C<refresh_via> does.

Choosing the address and writing it are one transaction.  C<BEGIN IMMEDIATE>
takes the write lock before the search for a free address.  So if two
provisions run at the same time, the second waits, searches again, and finds
the address taken.

=cut

sub assign {
    my ( $domain, $pool, $bin ) = @_;
    $bin //= $GUESTS;

    my %bins     = bins($pool);
    my @pool_ips = pool_ips( $bins{$bin} // {} );
    die "No [ip_pool] section or no IPs found in the $bin bin of the pool: cannot auto-assign IP for $domain\n"
      unless @pool_ips;

    # The server is asked before the lock, because ssh can take seconds and
    # every other provision waits on the lock.
    my $via     = $bins{$bin}{via};
    my $ask     = defined $via && !held_by( $domain, $bin );
    my %clients = $ask ? via_clients($via) : ();
    my %in_bin  = map { $_ => 1 } @pool_ips;

    my $db = dbh();

    # Not DEFERRED: a deferred transaction takes no lock until its first write,
    # and by then the other run can read the same free address.
    $db->do('BEGIN IMMEDIATE');

    my $chosen = eval {
        my $held = held_by( $domain, $bin );
        if ($held) {
            $db->do('COMMIT');
            return $held;
        }

        note_clients( $db, $bin, $bins{$bin}, \%clients, $domain ) if $ask;

        my $taken = taken();
        my $own   = $clients{$domain};
        my $free  = defined $own && $in_bin{$own} && !$taken->{$own} ? $own : first { !$taken->{$_} } @pool_ips;
        die "IP pool exhausted: no IPs available for $domain\n" unless $free;

        $db->do( "INSERT INTO ips (ip, domain, kind, bin) VALUES (?, ?, 'domain', ?)", undef, $free, $domain, $bin );
        $db->do('COMMIT');

        return $free;
    };

    if ( !defined $chosen ) {
        my $err = $@ || "Could not assign an IP to $domain\n";
        eval { $db->do('ROLLBACK') };    ## no critic (ErrorHandling::RequireCheckingReturnValueOfEval) -- report $err, not a failed rollback after it
        die $err;
    }

    return $chosen;
}

=head2 forget_seeding()

Deletes the record of which hypervisors were seeded, so the next seed asks each
of them again.  Returns the number of records it deleted.

=cut

sub forget_seeding {
    my $rows = dbh()->do('DELETE FROM seeded');
    return $rows && $rows ne '0E0' ? $rows : 0;
}

=head2 clear_reservations()

Deletes each reservation: the hypervisors, the gateways, and the other machines
that answered on the network.  Returns the number it deleted.

A reservation records what a seed found, not a decision.  So a reseed makes them
again from the start, and an address that no longer answers becomes free.

This does not delete assignments, and it must not.  An assignment is a decision:
a guest uses that address, or a provision is about to.  A machine that is off
during a sweep does not make its address free.

=cut

sub clear_reservations {
    my $rows = dbh()->do("DELETE FROM ips WHERE kind = 'reserved'");
    return $rows && $rows ne '0E0' ? $rows : 0;
}

=head2 ensure_seeded($pool, $gateway)

Fills the database from the addresses that are already in use, once for each
hypervisor.  Returns what C<seed> returns.

Each entry point can call this.  It skips each hypervisor that it seeded before,
so it asks no hypervisor twice.

Dies if it cannot connect to a hypervisor.  A database with half the fleet
in it gives out addresses that guests already use.  The seed does not mark that
hypervisor as done, so the next run tries it again.

=cut

sub ensure_seeded {
    my ( $pool, $gateway ) = @_;
    return seed( $pool, $gateway );
}

=head2 seed($pool, $gateway)

Records the address of each guest on each hypervisor.  It also reserves the
addresses of the hypervisors, C<$gateway>, and other machines that answer.
Returns the number of addresses it recorded.

The caller passes the gateway rather than this reading it, because the
configuration it comes out of is the one that caller was given, which is not
always the one L<Trog::Config> names.

The list of guests comes from the hypervisors, not from the configuration.  A
hypervisor reports what it runs, but somebody can edit a file.  The address
of each guest comes from its own F<provision.conf>, which is what it was built
with.

It records an address only when it is in the C<guests> bin of the pool.  C<assign> cannot give out
an address outside the pool, so a row for one is noise.

Another machine that answers is an address in the pool that answers a ping from
the hypervisor, or that the neighbor table of its bridge holds as C<REACHABLE>,
and that no guest holds.  Its name is C<insitu:> and its hardware address, or
C<unknown> if the table has none.  An entry that is out of date reserves an
address that is free.  That is the safe error, because the other error gives
out an address that is in use.  A hypervisor that names no bridge device is not
swept.

=cut

sub seed {
    my ( $pool, $gateway ) = @_;

    my $recorded = 0;
    my %bins     = bins($pool);
    my %in_pool  = map { $_ => 1 } pool_ips( $bins{$GUESTS} // {} );

    # The gateway goes first, so that its row names it as the gateway and not
    # as one more machine that answered.
    $recorded += reserve( $gateway, "gateway:$gateway" ) if defined $gateway && $in_pool{$gateway};

    my $db    = dbh();
    my %done  = map { $_->[0] => 1 } @{ $db->selectall_arrayref('SELECT source FROM seeded') };
    my $fleet = Trog::Hypervisors->load( Trog::Hypervisors->default_path() );

    foreach my $name ( $fleet->configured ? $fleet->names : () ) {

        # Once per hypervisor.  The marker at the end of this loop is written
        # only after the hypervisor answers everything, so a failure is retried.
        next if $done{"hv:$name"};

        my $hv = $fleet->hypervisor($name);

        # A hypervisor that gives its guests their own addresses uses none from
        # this pool.  It is usually a cloud, which has no libvirt domain list.
        next if $hv->manages_addresses;

        # The sweep goes first, because it fills the neighbor table.  libvirt
        # knows the bridged address of a guest only if the host spoke to it
        # lately.  It runs on the hypervisor, because this machine can be on a
        # different network.  A hypervisor with no bridge device is not swept.
        my $bridge = %in_pool && eval { $hv->bridge_device };
        my $swept  = q{};
        if ($bridge) {

            # An answer to the ping is the main signal.  A REACHABLE entry in
            # the table is a second one, and the table also gives the hardware
            # address.  REACHABLE alone is not reliable: an entry can decay to
            # STALE before the read.
            #
            # Do not quote each address.  They are numbers, and a quote inside
            # the script closes the quoting of the sh -c around it.
            my $script = join q{ }, map { "(ping -c1 -W1 $_ >/dev/null 2>&1 && echo LIVE $_) &" } grep { m/\A\d+(?:[.]\d+){3}\z/ } sort keys %in_pool;
            $script .= " wait; ip -4 neigh show dev $bridge";
            ( my $quoted = $script ) =~ s/'/'\\''/g;
            $swept = $hv->capture_cmd("sudo sh -c '$quoted'") // q{};
        }

        # STALE is not a signal.  It outlives the machine, so reserving it
        # leaks the pool.
        my %mac  = $swept =~ m/^(\d+(?:[.]\d+){3})\h+lladdr\h+(\S+)/mg;
        my %live = map { $_ => 1 } ( $swept =~ m/^LIVE\h+(\d+(?:[.]\d+){3})$/mg ), ( $swept =~ m/^(\d+(?:[.]\d+){3})\h+lladdr\h+\S+\N*\bREACHABLE\b/mg );

        # The address of each guest comes from its provision.conf.  libvirt
        # knows that a guest exists, but not the address it was built with,
        # and the neighbor table misses a quiet guest and keeps the address of
        # a destroyed one.  No eval, on purpose: see ensure_seeded.
        my @names = map { $_->get_name() } $hv->vmm->list_all_domains();
        if (@names) {
            my $dir    = $hv->domain_dir;
            my $script = join "\n", map {
                ( my $q = $_ ) =~ s/'/'\\''/g;
                "printf '%s\\t%s\\n' '$q' \"\$(grep -oE '^[[:space:]]*ips[[:space:]]*=[[:space:]]*[0-9.]+' '$dir/$q/provision.conf' 2>/dev/null | grep -oE '[0-9.]+' | head -1)\""
            } @names;

            # Also ask libvirt for the address of each guest.  This finds a
            # guest whose provision.conf is missing or cannot be read.
            #
            # This runs virsh on the hypervisor, not Sys::Virt from here.  The
            # ARP source reads the neighbor table of the client.  This machine
            # is not on the bridge of the guests, so from here it reports only
            # the NAT address.
            $script .= "\n" . join "\n", map {
                ( my $q = $_ ) =~ s/'/'\\''/g;
                "virsh domifaddr '$q' --source arp 2>/dev/null | grep -oE '[0-9]+(\\.[0-9]+){3}' | sed -e \"s|^|$q\t|\"";
            } @names;

            ( my $quoted = $script ) =~ s/'/'\\''/g;
            my $said = $hv->capture_cmd("sudo sh -c '$quoted'") // q{};

            # A guest also answers on the NAT bridge, and libvirt gives out
            # those addresses, not this pool.
            my @found = $said =~ m/^([^\t\n]+)\t(\d+(?:[.]\d+){3})$/mg;
            while ( my ( $domain, $ip ) = splice( @found, 0, 2 ) ) {
                $recorded += record( $ip, $domain ) if $in_pool{$ip};
            }
        }

        # The hypervisor goes before the machines that answered, so that its row
        # names it.  Its address comes from the host part of its libvirt URI.
        # If that name does not resolve, nothing is reserved for it.
        my $host   = eval { $hv->ssh_host };
        my $packed = $host   && Socket::inet_aton($host);
        my $ip     = $packed && Socket::inet_ntoa($packed);
        $recorded += reserve( $ip, "hv:$name" ) if $ip && $in_pool{$ip};

        # Other machines that answer, for example a printer or a router.  An
        # address in the pool that answers and that no guest holds belongs to
        # some other machine, so it is reserved.
        my $already = taken();
        foreach my $found ( grep { $in_pool{$_} && !$already->{$_} } sort keys %live ) {
            $recorded += reserve( $found, 'insitu:' . ( $mac{$found} // 'unknown' ) );
        }

        $db->do( 'INSERT OR IGNORE INTO seeded (source) VALUES (?)', undef, "hv:$name" );
    }

    return $recorded;
}

1;
