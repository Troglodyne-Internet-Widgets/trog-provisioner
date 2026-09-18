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

use Config::Simple;

use Trog::Config();
use Trog::SQLite();

=head1 NAME

Provisioner::IPPool - assign static IP addresses from a pool, and record which are taken

=head1 SYNOPSIS

    use Provisioner::IPPool;

    # Only the scripts in bin/ use this interface.
    my $pool_block = { addresses => '10.0.0.5 10.0.0.6', cidr => '10.0.1.0/29' };

    my @ips = Provisioner::IPPool::pool_ips($pool_block);
    my $ip  = Provisioner::IPPool::assign( 'test.test', $pool_block );

=head2 SUBROUTINES

=head3 pool_ips($pool)

C<$pool> is the C<[ip_pool]> block of F<ipmap.cfg>, as a hash reference.
C<addresses> is a list of addresses and C<cidr> is a list of CIDR blocks.
Whitespace separates the items in each list.

Returns each address in the pool once, in order.  Dies if a CIDR block is not
valid.

=cut

sub pool_ips {
    my ($pool) = @_;
    my ( %seen, @ips );

    if ( my $addrs = $pool->{addresses} ) {
        for my $ip ( split /\s+/, $addrs ) {
            next unless $ip =~ /\S/;
            push @ips, $ip unless $seen{$ip}++;
        }
    }

    if ( my $cidrs = $pool->{cidr} ) {
        for my $cidr ( split /\s+/, $cidrs ) {
            next unless $cidr =~ /\S/;
            my $net = Net::IP->new($cidr)
              or die "Invalid CIDR '$cidr': " . Net::IP::Error() . "\n";

            my @block;
            do {
                push @block, $net->ip();
            } while ( ++$net );

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
    }

    return @ips;
}

=head1 WHY A DATABASE

Two runs cannot safely share a file of assignments.  Both read it, both find the
same free address, and both write it.  The second write wins.  Two guests then
get the same address, and nothing reports an error.  You find out later, when
you cannot connect to one of them.

So the assignments are in SQLite, and each assignment is one transaction.  The
row goes in, or the address is already taken and C<assign> tries the next one.
F<ipmap.cfg> still gives the range of the pool, in C<[ip_pool]>.

=head3 db_path()

Returns the path of the database.  This is F<ips.db>, in the same directory as
the rest of the configuration.

=cut

sub db_path { return Trog::Config->path('ips.db') }

=head3 schema_path()

Returns the absolute path of F<schema/ips.sql> in this checkout.  The path is
relative to this file, as C<bin/new_config> finds its scripts.

=cut

sub schema_path {
    return Cwd::abs_path( File::Basename::dirname(__FILE__) . '/../../schema/ips.sql' );
}

=head3 dbh()

Returns a handle on the database at C<db_path>, with the schema applied.

=cut

sub dbh { return Trog::SQLite::dbh( schema_path(), db_path() ) }

=head3 assignments()

Returns a hash reference of each guest domain to its address.  Reservations
are not in it.  C<bin/new_config> gives this to the templates as C<ipmap>, and
the pdns zone makes its records from it.

=cut

sub assignments {
    my $rows = dbh()->selectall_arrayref( "SELECT domain, ip FROM ips WHERE kind = 'domain'", { Slice => {} } );
    return { map { $_->{domain} => $_->{ip} } @$rows };
}

=head3 taken()

Returns a hash reference of each address in the database to the name that holds
it.  Reservations are in it, because a reserved address is not free.

=cut

sub taken {
    my $rows = dbh()->selectall_arrayref( 'SELECT ip, domain FROM ips', { Slice => {} } );
    return { map { $_->{ip} => $_->{domain} } @$rows };
}

=head3 held_by($domain)

Returns the address that C<$domain> has, or undef.

It looks at guests only.  A reservation is not a domain, and C<release> must
never report that it gave back the gateway.

=cut

sub held_by {
    my ($domain) = @_;
    my $row = dbh()->selectrow_arrayref( "SELECT ip FROM ips WHERE domain = ? AND kind = 'domain'", undef, $domain );
    return $row ? $row->[0] : undef;
}

=head3 reserve($ip, $name)

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

=head3 record($ip, $domain)

Records C<$ip> as the address of the guest C<$domain>.  This is for an address
that a hypervisor reports, not one that C<assign> gave out.  Returns true if
this call wrote the row.

=cut

sub record {
    my ( $ip, $domain ) = @_;
    my $rows = dbh()->do( "INSERT OR IGNORE INTO ips (ip, domain, kind) VALUES (?, ?, 'domain')", undef, $ip, $domain );
    return $rows && $rows != 0 ? 1 : 0;
}

=head3 release($domain)

Gives back the address of C<$domain>.  Returns that address, or undef if the
domain held no address.

C<bin/destroy> calls this, and C<bin/reseed_ips> calls it for a domain that no
hypervisor runs.  A domain that you provision again keeps its address.

=cut

sub release {
    my ($domain) = @_;

    my $db = dbh();
    my $ip = held_by($domain) or return undef;
    $db->do( "DELETE FROM ips WHERE domain = ? AND kind = 'domain'", undef, $domain );

    return $ip;
}

=head3 assign($domain, $pool)

Returns the address of C<$domain>.  If the domain has no address, this gives it
the first free address in C<$pool>.  If it has one, this returns that address
and writes nothing.

Dies if the pool has no addresses, or if no address in it is free.

Choosing the address and writing it are one transaction.  C<BEGIN IMMEDIATE>
takes the write lock before the search for a free address.  So if two
provisions run at the same time, the second waits, searches again, and finds
the address taken.

=cut

sub assign {
    my ( $domain, $pool ) = @_;

    my @pool_ips = pool_ips($pool);
    die "No [ip_pool] section or no IPs found in pool: cannot auto-assign IP for $domain\n"
      unless @pool_ips;

    my $db = dbh();

    # Not DEFERRED: a deferred transaction takes no lock until its first write,
    # and by then the other run can read the same free address.
    $db->do('BEGIN IMMEDIATE');

    my $chosen = eval {
        my $held = held_by($domain);
        if ($held) {
            $db->do('COMMIT');
            return $held;
        }

        my $taken = taken();
        my $free  = first { !$taken->{$_} } @pool_ips;
        die "IP pool exhausted: no IPs available for $domain\n" unless $free;

        $db->do( "INSERT INTO ips (ip, domain, kind) VALUES (?, ?, 'domain')", undef, $free, $domain );
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

=head3 forget_seeding()

Deletes the record of which hypervisors were seeded, so the next seed asks each
of them again.  Returns the number of records it deleted.

=cut

sub forget_seeding {
    my $rows = dbh()->do('DELETE FROM seeded');
    return $rows && $rows ne '0E0' ? $rows : 0;
}

=head3 clear_reservations()

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

=head3 ensure_seeded($pool)

Fills the database from the addresses that are already in use, once for each
hypervisor.  Returns what C<seed> returns.

Each entry point can call this.  It skips each hypervisor that it seeded before,
so it asks no hypervisor twice.

Dies if it cannot connect to a hypervisor.  A database with half the fleet
in it gives out addresses that guests already use.  The seed does not mark that
hypervisor as done, so the next run tries it again.

=cut

sub ensure_seeded {
    my ($pool) = @_;
    return seed($pool);
}

=head3 seed($pool)

Records the address of each guest on each hypervisor.  It also reserves the
addresses of the hypervisors, the gateway, and other machines that answer.
Returns the number of addresses it recorded.

The list of guests comes from the hypervisors, not from F<ipmap.cfg>.  A
hypervisor reports what it runs, but somebody can edit the file.  The address
of each guest comes from its own F<provision.conf>, which is what it was built
with.

It records an address only when it is in the pool.  C<assign> cannot give out
an address outside the pool, so a row for one is noise.

=cut

sub seed {
    my ($pool) = @_;

    # Not loaded at the top: it loads Sys::Virt and an SSH stack.  A database
    # that is already seeded, and the tests, do not need them.
    require Trog::Hypervisors;

    my $recorded = 0;
    my %in_pool  = map { $_ => 1 } pool_ips($pool);

    # The gateway goes first, so that its row names it as the gateway and not
    # as one more machine that answered.
    my $ipmap   = Config::Simple->new( Trog::Config->path('ipmap.cfg') );
    my $global  = $ipmap ? ( $ipmap->param( -block => 'global' ) // {} ) : {};
    my $gateway = $global->{gateway} // q{};
    foreach my $gw ( grep { $_ } split /[\s,]+/, $gateway ) {
        $recorded += reserve( $gw, "gateway:$gw" ) if $in_pool{$gw};
    }

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
        # knows the bridged address of a guest only if the host spoke to it lately.
        my @live = _live_addresses( $hv, [ sort keys %in_pool ] );

        foreach my $found ( _guest_addresses($hv) ) {

            # A guest also answers on the NAT bridge, and libvirt gives out
            # those addresses, not this pool.
            next unless $in_pool{ $found->{ip} };
            $recorded += record( $found->{ip}, $found->{domain} );
        }

        # The hypervisor goes before the sweep results, so that its row names it.
        # Its address comes from the host part of its libvirt URI.  If that name
        # does not resolve, nothing is reserved for it.
        my $host = eval { $hv->ssh_host };
        my $ip   = $host ? _resolve($host) : undef;
        $recorded += reserve( $ip, "hv:$name" ) if $ip && $in_pool{$ip};

        # Other machines that answer, for example a printer or a router.  The
        # guests above tell us nothing about the rest of the network.
        my $already = taken();
        foreach my $found (@live) {

            # The neighbor table holds each address the hypervisor spoke to
            # lately.  Only an address in the pool needs a row.
            next unless $in_pool{ $found->{ip} };

            # An address that answers and that no guest holds belongs to some
            # other machine, so it is reserved.
            next if $already->{ $found->{ip} };
            $recorded += reserve( $found->{ip}, "insitu:$found->{mac}" );
        }

        $db->do( 'INSERT OR IGNORE INTO seeded (source) VALUES (?)', undef, "hv:$name" );
    }

    return $recorded;
}

=head3 _guest_addresses($hv)

Returns a list of hash references with the keys C<domain> and C<ip>, one for
each address of each guest on C<$hv>.  A guest can appear more than once.

It reads the address from the F<provision.conf> of each guest.  libvirt knows
that a guest exists, but not the address it was built with.  The neighbor table
misses a quiet guest and keeps the address of a destroyed one.  The command
runs on the hypervisor once, not once for each domain.

Dies if it cannot connect to libvirt on C<$hv>.  C<ensure_seeded> says why.

=cut

sub _guest_addresses {
    my ($hv) = @_;

    # No eval, on purpose.  See ensure_seeded.
    my @names = map { $_->get_name() } $hv->vmm->list_all_domains();
    return () unless @names;

    my $dir    = $hv->domain_dir;
    my $script = join "\n", map {
        ( my $q = $_ ) =~ s/'/'\\''/g;
        "printf '%s\\t%s\\n' '$q' \"\$(grep -oE '^[[:space:]]*ips[[:space:]]*=[[:space:]]*[0-9.]+' '$dir/$q/provision.conf' 2>/dev/null | grep -oE '[0-9.]+' | head -1)\""
    } @names;

    # Also ask libvirt for the address of each guest.  This finds a guest whose
    # provision.conf is missing or cannot be read.
    #
    # This runs virsh on the hypervisor, not Sys::Virt from here.  The ARP
    # source reads the neighbor table of the client.  This machine is not on
    # the bridge of the guests, so from here it reports only the NAT address.
    $script .= "\n" . join "\n", map {
        ( my $q = $_ ) =~ s/'/'\\''/g;
        "virsh domifaddr '$q' --source arp 2>/dev/null | grep -oE '[0-9]+(\\.[0-9]+){3}' | sed -e \"s|^|$q\t|\"";
    } @names;

    ( my $quoted = $script ) =~ s/'/'\\''/g;
    my $said = $hv->capture_cmd("sudo sh -c '$quoted'") // q{};

    my ( @found, %seen );
    foreach my $line ( split m/\n/, $said ) {
        my ( $domain, $ip ) = split m/\t/, $line, 2;
        next unless $domain;
        next unless defined $ip && $ip =~ m/\A\d+(?:[.]\d+){3}\z/;

        # A domain also answers on the NAT bridge, so it can appear twice.  The
        # caller knows the pool, so the caller picks the address in it.
        next if $seen{"$domain\t$ip"}++;
        push( @found, { domain => $domain, ip => $ip } );
    }

    return @found;
}

=head3 _live_addresses($hv, $pool)

C<$pool> is an array reference of addresses.  Returns a list of hash references
with the keys C<ip> and C<mac>, one for each address that answers now.  The
C<mac> is C<unknown> if the neighbor table has none.  Returns an empty list if
C<$pool> is empty or C<$hv> has no bridge device.

It pings each address in the pool from the hypervisor, and then reads the
neighbor table of the bridge there.  The table holds only the addresses that
the host spoke to lately, so the ping comes first.  libvirt reads the same table
for C<virsh domifaddr --source arp>.  This machine can be on a different
network, so the sweep runs on the hypervisor.

An entry that is out of date reserves an address that is free.  That is the safe
error, because the other error gives out an address that is in use.

=cut

sub _live_addresses {
    my ( $hv, $pool ) = @_;
    return () unless @$pool;

    my $bridge = eval { $hv->bridge_device } or return ();

    # An answer to the ping is the main signal.  A REACHABLE entry in the table
    # is a second signal, and the table also gives the hardware address.
    # REACHABLE alone is not reliable: an entry can decay to STALE before the read.
    #
    # STALE is not a signal.  It outlives the machine, so reserving it leaks the pool.
    #
    # Do not quote each address.  They are numbers, and a quote inside the
    # script closes the quoting of the sh -c around it.
    my @addresses = grep { m/\A\d+(?:[.]\d+){3}\z/ } @$pool;
    my $script    = join q{ }, map { "(ping -c1 -W1 $_ >/dev/null 2>&1 && echo LIVE $_) &" } @addresses;
    $script .= " wait; ip -4 neigh show dev $bridge";

    ( my $quoted = $script ) =~ s/'/'\\''/g;
    my $said = $hv->capture_cmd("sudo sh -c '$quoted'") // q{};

    my ( %live, %mac );
    foreach my $line ( split m/\n/, $said ) {
        if ( my ($answered) = $line =~ m/\ALIVE\s+(\d+(?:[.]\d+){3})\z/ ) {
            $live{$answered} = 1;
            next;
        }

        my ( $ip, $hw ) = $line =~ m/\A(\d+(?:[.]\d+){3})\s+lladdr\s+(\S+)/ or next;
        $mac{$ip}  = $hw;
        $live{$ip} = 1 if $line =~ m/\bREACHABLE\b/;
    }

    return map { { ip => $_, mac => $mac{$_} // 'unknown' } } sort keys %live;
}

=head3 _resolve($host)

Returns C<$host> if it is already an IPv4 address.  If not, returns the address
that the resolver gives, or undef.  It does not die, because the seed skips a
hypervisor that does not resolve and records the rest.

=cut

sub _resolve {
    my ($host) = @_;
    return $host if $host =~ m/\A\d+(?:[.]\d+){3}\z/;

    require Socket;
    my $packed = Socket::inet_aton($host) or return undef;
    return Socket::inet_ntoa($packed);
}

1;
