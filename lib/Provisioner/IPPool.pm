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

=head3 forget_seeding()

Drop the record of which hypervisors have been interrogated, so the next seed
asks all of them again.  Returns how many were forgotten.

=cut

sub forget_seeding {
    my $rows = dbh()->do('DELETE FROM seeded');
    return $rows && $rows ne '0E0' ? $rows : 0;
}

=head3 clear_reservations()

Drop every reservation -- the hypervisors, the gateways, and whatever else was
found answering.  Returns how many went.

These are B<derived> state: a note of what was observed to be there, not a
decision anybody made.  So a reseed rebuilds them from scratch, and an address
that has since gone quiet is correctly freed rather than reserved forever.

Assignments are not touched, and must not be.  A domain holding an address is a
decision -- something has been told it lives there, or is about to be built on
it -- and a machine that happens to be switched off during a sweep is not
evidence that its address is free.

=cut

sub clear_reservations {
    my $rows = dbh()->do("DELETE FROM ips WHERE kind = 'reserved'");
    return $rows && $rows ne '0E0' ? $rows : 0;
}

=head3 ensure_seeded($pool)

Fill the database from what is already out there, once per hypervisor.

Safe to call from every entry point: a hypervisor that has already been
interrogated is skipped, so this does nothing on all but the first run.

B<Dies if a hypervisor cannot be reached.>  Seeding half a fleet and then
handing out addresses is exactly the stomping this exists to prevent, so a
hypervisor that will not answer stops the run rather than producing a database
that is quietly missing every guest on it.  Nothing is written for it, so the
next run tries again.

=cut

sub ensure_seeded {
    my ($pool) = @_;
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

    # The gateway first, so that it is recorded as the gateway rather than as
    # one more thing answering on the wire.  Handing a guest its own gateway is
    # the sort of thing that looks like a network fault for a day.
    my $ipmap   = Config::Simple->new( Trog::Config->path('ipmap.cfg') );
    my $global  = $ipmap ? ( $ipmap->param( -block => 'global' ) // {} ) : {};
    my $gateway = $global->{gateway} // q{};
    foreach my $gw ( grep { length } split /[\s,]+/, $gateway ) {
        $recorded += reserve( $gw, "gateway:$gw" ) if $in_pool{$gw};
    }

    my $db    = dbh();
    my %done  = map { $_->[0] => 1 } @{ $db->selectall_arrayref('SELECT source FROM seeded') };
    my $fleet = Trog::Hypervisors->load( Trog::Hypervisors->default_path() );

    foreach my $name ( $fleet->configured ? $fleet->names : () ) {

        # Once per hypervisor, and recorded as done only after it has answered
        # everything.  A sweep is not free and a fleet does not change often, so
        # this is not work to repeat on every provision -- but a hypervisor that
        # could not be reached is one to come back to rather than write off.
        next if $done{"hv:$name"};

        my $hv = $fleet->hypervisor($name);

        # The sweep first, because what comes after reads the neighbour table it
        # fills: libvirt only knows a guest's bridged address if the host has
        # spoken to it lately.
        my @live = _live_addresses( $hv, [ sort keys %in_pool ] );

        foreach my $found ( _guest_addresses($hv) ) {

            # A guest answers on the NAT bridge too, and that address is
            # libvirt's to hand out rather than ours.
            next unless $in_pool{ $found->{ip} };
            $recorded += record( $found->{ip}, $found->{domain} );
        }

        # The hypervisor itself, before the sweep results below, so it is named
        # for what it is.  hypervisors.conf gives it as the host half of the
        # libvirt URI, so that is what gets resolved; one we cannot resolve is
        # not one whose address we can protect.
        my $host = eval { $hv->ssh_host };
        my $ip   = $host ? _resolve($host) : undef;
        $recorded += reserve( $ip, "hv:$name" ) if $ip && $in_pool{$ip};

        # Whatever else is answering.  The guests above come from what they were
        # configured with and what libvirt claims, which says nothing about the
        # rest of the network -- a printer, a router, somebody's media box.
        my $already = taken();
        foreach my $found (@live) {

            # In the pool only.  The table holds whatever the hypervisor has
            # spoken to lately, most of which is none of our business: an
            # address we could never hand out is not worth a row saying so.
            next unless $in_pool{ $found->{ip} };

            # Answering, and not one of ours -- no guest was configured with it
            # and libvirt did not claim it.  Somebody else's machine, so it is
            # spoken for whatever we think.
            next if $already->{ $found->{ip} };
            $recorded += reserve( $found->{ip}, "insitu:$found->{mac}" );
        }

        $db->do( 'INSERT OR IGNORE INTO seeded (source) VALUES (?)', undef, "hv:$name" );
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

    # Not wrapped in an eval.  A hypervisor that cannot be reached is the one
    # case where carrying on is worse than stopping: seeding half a fleet and
    # then handing out addresses is exactly the stomping this exists to prevent,
    # and swallowing the error is how a database ended up holding one row and
    # calling itself seeded.
    my @names = map { $_->get_name() } $hv->vmm->list_all_domains();
    return () unless @names;

    my $dir    = $hv->domain_dir;
    my $script = join "\n", map {
        ( my $q = $_ ) =~ s/'/'\\''/g;
        "printf '%s\\t%s\\n' '$q' \"\$(grep -oE '^[[:space:]]*ips[[:space:]]*=[[:space:]]*[0-9.]+' '$dir/$q/provision.conf' 2>/dev/null | grep -oE '[0-9.]+' | head -1)\""
    } @names;

    # And what libvirt says each guest is answering on, which catches one whose
    # provision.conf is missing or unreadable.
    #
    # Through virsh on the hypervisor rather than through Sys::Virt over the
    # connection we already hold, because the ARP source resolves against the
    # *client's* neighbour table: asked from here, where this machine is not on
    # the guests' bridge, it reports the NAT address and nothing else.  Asked on
    # the hypervisor it reports the bridged one.  That is the whole difference,
    # and it is why this shells out.
    $script .= "\n" . join "\n", map {
        ( my $q = $_ ) =~ s/'/'\\''/g;
        "virsh domifaddr '$q' --source arp 2>/dev/null | grep -oE '[0-9]+(\\.[0-9]+){3}' | sed -e \"s|^|$q\t|\"";
    } @names;

    ( my $quoted = $script ) =~ s/'/'\\''/g;
    my $said = $hv->capture("sudo sh -c '$quoted'") // q{};

    my ( @found, %seen );
    foreach my $line ( split "\n", $said ) {
        my ( $domain, $ip ) = split "\t", $line, 2;
        next unless defined $domain && length $domain;
        next unless defined $ip     && $ip =~ m/\A[0-9]+(?:[.][0-9]+){3}\z/;

        # A domain answers on the NAT bridge as well, so it turns up more than
        # once.  Which of its addresses belongs to the pool is decided by the
        # caller, which is the only thing that knows what the pool is.
        next if $seen{"$domain\t$ip"}++;
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

    # Two signals, because one of them is not trustworthy on its own.
    #
    # Whether the ping was answered is the reliable one: three identical sweeps
    # reported twelve, twelve and twelve.  Whether the neighbour table says
    # REACHABLE is not: the same three sweeps read twelve, twelve and two, the
    # entries having decayed to STALE between the sweep and the read.  So the
    # ping reports for itself, and the table is consulted for a second opinion
    # and for the hardware address.
    #
    # STALE is deliberately not a signal.  It outlives the machine that put it
    # there -- addresses belonging to guests destroyed days earlier were still
    # in this table, and reserving those would leak the pool a little at a time.
    #
    # Unquoted addresses, then the whole script quoted once: these come out of
    # the pool as numbers and need no quoting of their own, and quoting them
    # individually closed the sh -c around them, so the sweep never ran at all.
    my @addresses = grep { m/\A[0-9]+(?:[.][0-9]+){3}\z/ } @$pool;
    my $script    = join q{ }, map { "(ping -c1 -W1 $_ >/dev/null 2>&1 && echo LIVE $_) &" } @addresses;
    $script .= " wait; ip -4 neigh show dev $bridge";

    ( my $quoted = $script ) =~ s/'/'\\''/g;
    my $said = $hv->capture("sudo sh -c '$quoted'") // q{};

    my ( %live, %mac );
    foreach my $line ( split "\n", $said ) {
        if ( my ($answered) = $line =~ m/\ALIVE\s+([0-9]+(?:[.][0-9]+){3})\z/ ) {
            $live{$answered} = 1;
            next;
        }

        my ( $ip, $hw ) = $line =~ m/\A([0-9]+(?:[.][0-9]+){3})\s+lladdr\s+(\S+)/ or next;
        $mac{$ip}  = $hw;
        $live{$ip} = 1 if $line =~ m/\bREACHABLE\b/;
    }

    return map { { ip => $_, mac => $mac{$_} // 'unknown' } } sort keys %live;
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
