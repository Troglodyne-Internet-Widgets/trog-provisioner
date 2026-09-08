package Provisioner::IPPool;

#ABSTRACT: Shared static IP pool helpers for new_config and list_ip_pool.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use Cwd();
use File::Basename();
use List::Util qw{first};
use Net::IP;

use Config::Simple;

use Trog::Config();
use Trog::SQLite();

=head1 NAME

Provisioner::IPPool - shared IP pool helpers for new_config and list_ip_pool

=head1 SYNOPSIS

    use Provisioner::IPPool;

    # not an interface for general consumption
    my $pool_block = { addresses => [], cidr => [] };

    my @ips = Provisioner::IPPool::pool_ips($pool_block);
    my $ip  = Provisioner::IPPool::assign( 'test.test', $pool_block );

=head2 SUBROUTINES

=head3 pool_ips($cfg_hashref)

Return ordered list of IPs from an ip_pool config block in ipmap.cfg.

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

            # The first and last address of an IPv4 block are the network and
            # the broadcast; neither belongs to a host.  Handing one out looks
            # like it worked right up until the guest cannot talk to anything.
            # A /31 is a point-to-point link where both addresses are usable
            # (RFC 3021), and a /32 is one host; neither has any to spare.
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

Assignments used to live in the C<[ips]> section of F<ipmap.cfg>, and a file is
not something two runs can share.  Both read it, both find the same first free
address, both write, and the second write wins -- so a fan-out of provisions
hands the same address to two guests and neither of them says so.  It is a race
you only notice later, when one of them cannot be reached.

So they live in SQLite instead, and an assignment is a transaction: the row
either goes in or the address was already taken and the next one is tried.
Nothing else about the pool changed -- F<ipmap.cfg> still says what the range
is, in C<[ip_pool]>.

=head3 db_path()

Where the database lives: F<ips.db> beside the rest of the configuration.

=cut

sub db_path { return Trog::Config->path('ips.db') }

=head3 schema_path()

The DDL, anchored to this checkout the way the generator anchors its scripts.

=cut

sub schema_path {
    return Cwd::abs_path( File::Basename::dirname(__FILE__) . '/../../schema/ips.sql' );
}

=head3 dbh()

The handle, schema applied.

=cut

sub dbh { return Trog::SQLite::dbh( schema_path(), db_path() ) }

=head3 assignments()

Every address that is spoken for, as a map of domain to address.  This is what
C<bin/new_config> hands templates as C<ipmap>, and what the pdns zone renders
its records out of, so it carries the guests and not the reservations.

=cut

sub assignments {
    my $rows = dbh()->selectall_arrayref( "SELECT domain, ip FROM ips WHERE kind = 'domain'", { Slice => {} } );
    return { map { $_->{domain} => $_->{ip} } @$rows };
}

=head3 taken()

Every address in the database whatever put it there, as a map of address to the
name against it.  Reservations included: the point of them is that they are not
available.

=cut

sub taken {
    my $rows = dbh()->selectall_arrayref( 'SELECT ip, domain FROM ips', { Slice => {} } );
    return { map { $_->{ip} => $_->{domain} } @$rows };
}

=head3 held_by($domain)

The address that domain already has, or undef.

Guests only.  A reservation is not a domain, and answering with one would let
C<release> report that it had given the gateway back -- which it must not, and
does not.

=cut

sub held_by {
    my ($domain) = @_;
    my $row = dbh()->selectrow_arrayref( "SELECT ip FROM ips WHERE domain = ? AND kind = 'domain'", undef, $domain );
    return $row ? $row->[0] : undef;
}

=head3 reserve($ip, $name)

Record an address as nobody's to hand out -- a hypervisor, a gateway.  Returns
true if this call is what recorded it.

Quiet about an address that is already there: seeding runs on every start and
has to be able to say the same thing twice.

=cut

sub reserve {
    my ( $ip, $name ) = @_;
    my $rows = dbh()->do( "INSERT OR IGNORE INTO ips (ip, domain, kind) VALUES (?, ?, 'reserved')", undef, $ip, $name );
    return $rows && $rows != 0 ? 1 : 0;
}

=head3 record($ip, $domain)

Record an address a guest already has, found by looking at a hypervisor rather
than handed out here.  Returns true if this call is what recorded it.

=cut

sub record {
    my ( $ip, $domain ) = @_;
    my $rows = dbh()->do( "INSERT OR IGNORE INTO ips (ip, domain, kind) VALUES (?, ?, 'domain')", undef, $ip, $domain );
    return $rows && $rows != 0 ? 1 : 0;
}

=head3 release($domain)

Give the address back.  Returns what was released, or undef if that domain held
nothing.

C<bin/destroy> calls this, which is the only thing that does: a re-provision
goes through C<bin/provision> and keeps what the domain already has.

=cut

sub release {
    my ($domain) = @_;

    my $db = dbh();
    my $ip = held_by($domain) or return undef;
    $db->do( "DELETE FROM ips WHERE domain = ? AND kind = 'domain'", undef, $domain );

    return $ip;
}

=head3 assign($domain, $pool)

The address for C<$domain>, assigning the first free one in the pool if it does
not have one yet.  Idempotent: a domain that already has an address is answered
with it and nothing is written.

Dies if the pool is unconfigured or exhausted.

The choosing and the writing are one transaction, and that is the whole point
of this module.  C<BEGIN IMMEDIATE> takes the write lock before the free
address is looked for, so two provisions running at once cannot both decide on
the same one -- the second waits, then looks again and finds it taken.

=cut

sub assign {
    my ( $domain, $pool ) = @_;

    my @pool_ips = pool_ips($pool);
    die "No [ip_pool] section or no IPs found in pool: cannot auto-assign IP for $domain\n"
      unless @pool_ips;

    my $db = dbh();

    # IMMEDIATE rather than DEFERRED: a deferred transaction takes no lock until
    # its first write, by which time the other run has read the same free
    # address out from under this one.
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
        eval { $db->do('ROLLBACK') };
        die $err;
    }

    return $chosen;
}

=head3 ensure_seeded($pool)

Fill an empty database from what is already out there, once.

A database with anything in it is left alone, so this is safe to call from
every entry point and does nothing on all but the first.

=cut

sub ensure_seeded {
    my ($pool) = @_;

    my $db  = dbh();
    my $any = $db->selectrow_arrayref('SELECT 1 FROM ips LIMIT 1');
    return 0 if $any;

    return seed($pool);
}

=head3 seed($pool)

Record what every hypervisor says its guests are using, plus the addresses that
belong to the infrastructure rather than to a guest.

The guests come off the hypervisors and not out of F<ipmap.cfg>: what a
hypervisor is running is a fact, where the file is a record somebody may have
edited.  Each domain's address is read from its own F<provision.conf>, which is
what the guest was actually built with.

The hypervisor and the gateway are recorded only when they fall inside the
configured pool.  Outside it they cannot be handed out anyway, and a row saying
so would be noise.

Returns the number of addresses recorded.

=cut

sub seed {
    my ($pool) = @_;

    # Required rather than used at the top: this brings Sys::Virt and an SSH
    # stack with it, and the common case -- a database that is already seeded --
    # should not pay for that, nor should the tests.
    require Trog::Hypervisors;

    my $recorded = 0;
    my %in_pool  = map { $_ => 1 } pool_ips($pool);

    my $fleet = Trog::Hypervisors->load( Trog::Hypervisors->default_path() );
    foreach my $name ( $fleet->configured ? $fleet->names : () ) {
        my $hv = eval { $fleet->hypervisor($name) } or next;

        foreach my $found ( _guest_addresses($hv) ) {
            $recorded += record( $found->{ip}, $found->{domain} );
        }

        # Anything else answering in the pool.  The guests above come from what
        # they were configured with, which says nothing about the rest of the
        # network -- a printer, a router, a machine nobody told us about.  Those
        # are found by asking the hypervisor what is on the wire.
        my $already = taken();
        foreach my $found ( _live_addresses( $hv, [ sort keys %in_pool ] ) ) {

            # In the pool only.  The table holds whatever the hypervisor has
            # spoken to lately, most of which is on the wider network and none
            # of our business: an address we could never hand out is not one
            # worth a row saying we will not.
            next unless $in_pool{ $found->{ip} };
            next if $already->{ $found->{ip} };
            $recorded += reserve( $found->{ip}, "insitu:$found->{mac}" );
        }

        # The hypervisor itself.  hypervisors.conf names it as the host half of
        # the libvirt URI, so that is what gets resolved; a hypervisor we cannot
        # resolve is not one whose address we can protect.
        my $host = eval { $hv->ssh_host } or next;
        my $ip   = _resolve($host)        or next;
        $recorded += reserve( $ip, "hv:$name" ) if $in_pool{$ip};
    }

    # Whatever the guests are told to route through.  Handing a guest its own
    # gateway is the sort of thing that looks like a network fault for a day.
    my $ipmap   = Config::Simple->new( Trog::Config->path('ipmap.cfg') );
    my $global  = $ipmap ? ( $ipmap->param( -block => 'global' ) // {} ) : {};
    my $gateway = $global->{gateway} // q{};
    foreach my $gw ( grep { length } split /[\s,]+/, $gateway ) {
        $recorded += reserve( $gw, "gateway:$gw" ) if $in_pool{$gw};
    }

    return $recorded;
}

# What each guest on this hypervisor was built with.  Asked of the hypervisor in
# one go rather than a connection per domain, and read out of each domain's own
# provision.conf: libvirt knows the guest exists but not what address it was
# configured with, and the ARP table only knows the ones it has spoken to
# lately -- it misses a quiet guest and keeps an address a destroyed one used to
# have, so it is wrong in both directions.
sub _guest_addresses {
    my ($hv) = @_;

    my @names = eval {
        map { $_->get_name() } $hv->vmm->list_all_domains();
    };
    return () unless @names;

    my $dir    = $hv->domain_dir;
    my $script = join "\n", map {
        ( my $q = $_ ) =~ s/'/'\\''/g;
        "printf '%s\\t%s\\n' '$q' \"\$(grep -oE '^[[:space:]]*ips[[:space:]]*=[[:space:]]*[0-9.]+' '$dir/$q/provision.conf' 2>/dev/null | grep -oE '[0-9.]+' | head -1)\""
    } @names;

    ( my $quoted = $script ) =~ s/'/'\\''/g;
    my $said = $hv->capture("sudo sh -c '$quoted'") // q{};

    my @found;
    foreach my $line ( split "\n", $said ) {
        my ( $domain, $ip ) = split "\t", $line, 2;
        next unless defined $domain && length $domain;
        next unless defined $ip     && $ip =~ m/\A[0-9]+(?:[.][0-9]+){3}\z/;
        push( @found, { domain => $domain, ip => $ip } );
    }

    return @found;
}

# What is answering in the pool right now, as a list of address and MAC.
#
# The hypervisor's own neighbour table, which is where libvirt gets what
# `virsh domifaddr --source arp` reports and what virt-manager shows.  It only
# holds an address the host has spoken to lately, so the pool is swept first --
# without that it knew two of this fleet's ten guests, and with it, eight, the
# other two being in the table under an interface domifaddr did not pick.
#
# Swept and read on the hypervisor rather than from here: this machine may not
# be on that network at all, and the table that matters is the one the guests
# share a bridge with.
#
# A stale entry costs an address that was actually free, which is the safe
# direction to be wrong in -- unlike handing out one somebody is answering on.
sub _live_addresses {
    my ( $hv, $pool ) = @_;
    return () unless @$pool;

    my $bridge = eval { $hv->bridge_device } or return ();
    my $sweep  = join q{ }, map { "ping -c1 -W1 '$_' >/dev/null 2>&1 &" } @$pool;

    my $said = $hv->capture("sudo sh -c '$sweep wait; ip -4 neigh show dev $bridge'") // q{};

    my @live;
    foreach my $line ( split "\n", $said ) {

        # FAILED and INCOMPLETE are the answers for an address nothing is on.
        next if $line =~ m/\b(?:FAILED|INCOMPLETE)\b/;
        my ( $ip, $mac ) = $line =~ m/\A([0-9]+(?:[.][0-9]+){3})\s+lladdr\s+(\S+)/ or next;
        push( @live, { ip => $ip, mac => $mac } );
    }

    return @live;
}

# Numeric already, or whatever the resolver says.  undef rather than a die: a
# hypervisor that does not resolve is a reason to skip its address, not a reason
# to stop everything else being recorded.
sub _resolve {
    my ($host) = @_;
    return $host if $host =~ m/\A[0-9]+(?:[.][0-9]+){3}\z/;

    require Socket;
    my $packed = Socket::inet_aton($host) or return undef;
    return Socket::inet_ntoa($packed);
}

1;
