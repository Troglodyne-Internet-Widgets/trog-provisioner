package Provisioner::Recipe::openvpn;

#ABSTRACT: Set up an OpenVPN server with an easy-rsa PKI.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Net::CIDR();
use Net::IP qw{$IP_A_IN_B_OVERLAP $IP_IDENTICAL $IP_NO_OVERLAP};

use Provisioner::IPPool();

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::openvpn

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        openvpn:
            port: 1194
            proto: udp
            subnet: 10.8.0.0
            netmask: 255.255.255.0
            cipher: AES-256-GCM
            # dns is optional. Without it, the server pushes no DNS servers to clients.
            interface: eth0
            redirect_gateway: false
            # Optional.  Without it, the halves of each cidr of the ip_pool.
            routes:
                - 192.0.2.0/25
                - 192.0.2.128/25

=head2 DESCRIPTION

Sets up an OpenVPN server and uses easy-rsa to manage its PKI.

The recipe makes a CA, a server certificate and key, DH parameters and a TLS
auth key under F</etc/openvpn/easy-rsa/pki>.  The server listens on the
configured port and protocol.  It pushes a route for the VPN subnet to clients.

The recipe renders a ufw application profile for its port and protocol.  If
the ufw recipe also runs, ufw allows that profile.

=head3 What it takes to route the traffic of a client

Three things are necessary, and two of them are not sufficient.

The recipe turns on C<net.ipv4.ip_forward>.  A MASQUERADE rule sends the VPN
subnet out of the guest with the address of the guest.  But a forwarded packet
meets the filter FORWARD chain first.  Ubuntu ships C</etc/default/ufw> with
C<DEFAULT_FORWARD_POLICY="DROP">.

So the third thing is an accept for the subnet in C<ufw-before-forward>.
Without it, the MASQUERADE rule is correct but no packet reaches it.  If
C<redirect-gateway> is on, a client that connects then loses all of its
connectivity.

C<setup-masquerade> writes the accept and the MASQUERADE rule.  The accept names
the VPN subnet.  The recipe does not set C<DEFAULT_FORWARD_POLICY="ACCEPT">,
because then the guest routes any traffic for anybody.

C<interface> names the interface that the MASQUERADE rule sends traffic out of.
The recipe does not choose it.  The name depends on how the guest booted, for
example C<ens3>, C<ens4> or C<enp1s0>.  A wrong name gives a rule that matches
nothing, and C<iptables> reports success.  If you omit it, C<setup-masquerade> asks
the guest which interface carries its default route when it writes the rule.

C<redirect_gateway> tells clients to send all of their traffic through the
tunnel, not only the traffic for hosts on the VPN.  The default is off.  The
server pushes this at connect time.  So a change takes effect on every deployed
client when it next reconnects.

=head3 The networks that a client reaches

C<routes> lists the networks that the server tells a client to send through the
tunnel, as CIDR blocks.  The guest forwards that traffic onto its own network,
and the MASQUERADE rule above gives it the address of the guest.  So a guest
of the installation answers a client with no route back to the VPN subnet.  The
C<A> records of the installation already hold the addresses of the guests, so
a name that resolves anywhere is reachable through the tunnel.

Without C<routes>, the recipe routes the C<ip_pool> in the C<_global> of the
installation, the pool that F<ips.db> hands addresses out of.  Each C<cidr>
block of each bin goes as its two halves, and each item of C<addresses> goes as
a C</32>.  A bin inside C<subnet> is not routed, because its addresses are the
clients of this server.  Without any, the server pushes no route.

The halves are for a client on a home network with the same numbers, such as
C<192.168.1.0/24>, the default of many home routers.  The client then has two
routes to the addresses of the guests, and the longer prefix wins.  A half is
longer than the home network, so traffic to a guest goes through the tunnel.

The cost is that the client cannot reach its own home network while it is
connected, for example its printer or its router, if that network has the same
numbers.  Its traffic for those addresses goes into the tunnel too.  If that
matters for a client, give C<routes> a C</32> for each guest, which takes only
those addresses away from the home network.

A guest of this installation on the network of this server reaches the
guests directly, so it ignores these routes.  See
L<Provisioner::Recipe::openvpnclient/A client on the same network as its server>.

=head3 The PKI is the part that cannot be made again

The recipe can make everything else again when it needs to.  A new CA is not
the same CA.  If the recipe makes a second one, no client certificate that the
first one signed is trusted any more.  The clients that hold them get no
message.

So the PKI makes the round trip through C<remote_files> and C<restores>.  The
C<data> target puts the salvaged PKI back before this fragment asks easyrsa for
anything.

The guard on PKI generation is not sufficient alone.  It stops generation only
when the old PKI is still on the disk, which is a re-provision.  A guest that is
built again from nothing has an empty disk.  It passes the guard and signs a new
CA for itself.  The restore that comes first prevents that.

C<remote_files> names a staged copy, not the PKI itself.
C<openvpn-stage-pki> writes it at F</etc/openvpn/pki-salvage>.  The fetch reads
the guest as root, so it can read the real PKI.  Issue #98 decides whether the recipe names the real PKI.
The staged copy also keeps the copy that travels apart from the one that the
running VPN uses.

The staged copy belongs to the admin user and nobody else can read it.  The mail
recipe makes the same trade to salvage its DKIM keys.  The admin account can
read the CA private key.  The key travels into the data directory, and into any
backup of that directory.  That is the cost of a VPN that survives the loss of
its guest.

The provision runs C<openvpn-stage-pki>, and so does C<remote_prepare> before
each fetch.  So a client certificate issued since the last provision is in the
copy that the next rebuild restores.

=head3 A configuration for a client

Not every client of the VPN is a guest that runs
L<Provisioner::Recipe::openvpnclient>.  For any other client, run this as root
on the server:

    openvpn-client-config NAME [REMOTE] > NAME.ovpn

It prints one file that C<openvpn --config> reads.  The CA, the certificate and key of the client, and the
C<tls-auth> key are inline.  The port, the protocol and the cipher are the ones
that the server uses.  C<REMOTE> is the name that the client connects to, and
defaults to the domain.

If C<NAME> has no certificate, the script issues one from the CA of the server
and runs C<openvpn-stage-pki>.  If it has one, the script prints the same
certificate again.  The output holds the private key of the client, so treat it
like a password.

=head3 Static addresses

A client can have an address that does not change, so that the guests can
reach it, and know it, by that address.  The address comes from a bin of the
C<ip_pool> that names this domain in C<via>.  See L<Provisioner::IPPool/BINS>.

    ip_pool:
        bins:
            vpnclients:
                cidr: 10.8.0.128/25
                via: vpn.test.test

The bin must be inside C<subnet>, at its top end, because the first two addresses
of C<subnet> are the network and the server.  The server hands out the
rest of C<subnet> to the clients without an address of their own.  No other bin
can have an address in C<subnet>.  So two openvpn servers with bins need two
different values of C<subnet>, because the default is the same for both.

    openvpn-client-config --address 10.8.0.129 NAME [REMOTE] > NAME.ovpn

This writes F</etc/openvpn/server/ccd/NAME>, which gives C<NAME> that address
at each connect.  It refuses an address that another client already has.  A
guest that runs L<Provisioner::Recipe::openvpnclient> with C<issue_from> gets
its address and its configuration this way when it is built.  C<bin/destroy>
revokes it, which removes the file.

Traffic from a static address to C<routes> is not masqueraded, so a guest sees
the address of the client.  Each guest has a route to the bin through this
domain, which F<ubuntu.network-config.tt> writes from C<via>.  Any other host
on those networks needs that route as well, for example on the router of the
network.  A guest built before the bin had C<via> gets the route when it is
built again.  The firewall of this guest also lets C<routes> open a connection
to the bin.

The salvage keeps F</etc/openvpn/server/ccd> with the PKI, so a rebuild of the
server keeps the address of each client.

An operator can also give an address to a client that is not a guest of this
installation, such as a laptop, with C<--address>.  Before
L<Provisioner::IPPool> hands out an address from the bin, it asks this server
for C<openvpn-list-clients --static>.  It reserves each address that the
server gives to a client that the database does not know, so that no guest
gets that address too.  A build that needs a new address from the bin dies
when this server cannot be asked.

=head3 Taking a client away

    openvpn-revoke-client NAME

This revokes the certificate of C<NAME>, signs a new revocation list, and gives
the list to the server.  openvpn reads the list at each TLS handshake, so a new
connection from C<NAME> fails at once.  A client that is connected keeps its
tunnel until its next renegotiation, which openvpn does each hour.

A revocation list expires C<easyrsa.crl_days> days after it is signed.  An
expired list stops B<every> client, because openvpn then refuses all
certificates.  So C<openvpn-refresh-crl> signs it again on each provision and
from cron each day.  The guest test fails when less than 30 days are left.

Run C<easyrsa revoke> through C<openvpn-revoke-client>, not by itself.  Alone,
it changes the index of the CA and not the list that the server reads.

=head3 When the CA expires

The CA expires C<easyrsa.ca_days> days after the guest that first made it.  The
salvage keeps the same CA on every rebuild, so a rebuild does not move that
date.  When the CA expires, the server and every client stop connecting.

So C<openvpn-ca-expiry> runs from cron each day.  Once the CA has
C<ca_warning_days> days or fewer left, it prints a warning, and cron mails it to
C<admin_email>.  Until then it prints nothing, and cron sends nothing.

=head3 Which clients there are

    openvpn-list-clients [--all | --static]

This lists each name that can connect, when its certificate expires, and its
tunnel address if it is connected now.  C<--all> also lists the revoked and the
expired certificates.  The script reads the index of the CA and the status file
of the server, which the server rewrites each minute.  C<--static> lists each
client with a static address instead, as its name, a tab, and the address.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;

    # This runs before validation, so the schema defaults are repeated here.  A
    # client opens one tunnel and keeps it, so a source that opens hundreds a
    # second is not a client.
    #
    # The limit names the configured protocol.  A limit with no protocol is a
    # tcp rule, and this server listens on udp by default.
    return ( ( $opts{port} // 1194 ) . '/' . ( $opts{proto} // 'udp' ) => 256 );
}

=head2 %jails = $recipe->jails(%opts)

A jail that bans a host that sends packets without the C<tls-auth> key.  Such
a host is not a client of this server, and openvpn logs it as one of these:

    TLS Error: cannot locate HMAC in incoming packet from [AF_INET]192.168.122.186:51342
    TLS Error: incoming packet authentication failed from [AF_INET]192.168.122.50:36431

openvpn logs to the journal, and the jail reads it there, so
L<Provisioner::Recipe::logshipper> forwards the same lines.  A line in the
journal starts with the host name and the unit, and so the expression is not
anchored at the start.

=cut

sub jails {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, as rate_limits does.
    return (
        'openvpn-tls' => {
            filter       => '',
            backend      => 'systemd',
            journalmatch => '_SYSTEMD_UNIT=openvpn-server@server.service',
            port         => $opts{port}  // 1194,
            protocol     => $opts{proto} // 'udp',
            failregex    => 'TLS Error: (?:cannot locate HMAC in incoming packet|incoming packet authentication failed) from \[AF_INET6?\]<HOST>:\d+',
        },
    );
}

=head2 $bool = $recipe->is_multi_tenant()

False.  The machine has one server, with one F</etc/openvpn/server> and one
C<openvpn-server@server>.  It has one easy-rsa PKI, and the CA has the name of
the domain that built it.

A second domain does not get a tunnel of its own.  It must issue from the CA of
the first domain, or replace that CA.  A new CA stops every client that already
has a certificate from connecting.

=cut

sub is_multi_tenant { return 0 }

sub args {
    return (
        properties => {
            port  => { type => 'integer', minimum => 1024,          default => 1194 },
            proto => { type => 'string',  enum    => [qw{udp tcp}], default => 'udp' },

            # An address is a string with a format.  The validator has no ipv4 type.
            subnet  => { type => 'string', format  => 'ipv4', default => '10.8.0.0' },
            netmask => { type => 'string', format  => 'ipv4', default => '255.255.255.0' },
            cipher  => { type => 'string', default => 'AES-256-GCM' },
            dns     => { type => 'array',  items   => { type => 'string' } },

            # No default, because only the guest knows the name.  See DESCRIPTION.
            interface => { type => 'string' },

            # Off, because a change reaches every deployed client.  See DESCRIPTION.
            redirect_gateway => { type => 'boolean', default => 0 },

            # The defaults are on the members, so that a block that sets one of
            # them still gets the rest.
            easyrsa => {
                type        => 'object',
                default     => {},
                description => 'What easyrsa signs with, rendered into its vars file.  The defaults are the defaults of easy-rsa 3.1.',
                properties  => {
                    key_size  => { type => 'integer', enum    => [ 2048, 3072, 4096 ],       default => 2048,     description => 'The RSA key size of each new key.' },
                    digest    => { type => 'string',  enum    => [qw{sha256 sha384 sha512}], default => 'sha256', description => 'The digest that each signature uses.' },
                    ca_days   => { type => 'integer', minimum => 1,                          default => 3650,     description => 'How long a new CA lasts.  The CA that a guest already has, or gets back from the salvage, keeps its own date.' },
                    cert_days => { type => 'integer', minimum => 1,                          default => 825,      description => 'How long a new client or server certificate lasts.' },
                    crl_days  => {
                        type        => 'integer',
                        minimum     => 31,
                        default     => 180,
                        description => 'How long a revocation list lasts.  Cron signs a new one each day, and the server refuses every client once the list expires, so this is how long a stopped cron goes unnoticed.  At least 31, which the guest test asks for.',
                    },
                },
            },

            ca_warning_days => {
                type        => 'integer',
                minimum     => 1,
                default     => 60,
                description => 'Mail admin_email each day once the CA has this many days or fewer left.  When the CA expires, no client and not the server can connect.',
            },

            # No default here, because the default comes from ip_pool.  See enrich.
            routes => {
                type        => 'array',
                description => 'The networks a client sends through the tunnel, as CIDR blocks.  The default is each cidr of ip_pool as its two halves, and each of its addresses as a /32.',
                items       => { type => 'string', pattern => '^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$' },
            },
        },
    );
}

# The netmask of a prefix length, as an integer.
my sub mask ($prefix) {
    return $prefix ? ( 0xFFFFFFFF << ( 32 - $prefix ) ) & 0xFFFFFFFF : 0;
}

# The address of a CIDR block with the host bits cleared, and its prefix
# length, so that 192.0.2.5/24 gives 192.0.2.0 and 24.
my sub network ($block) {
    my ( $address, $prefix ) = $block =~ m{\A(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})\z};
    die "'$block' is not an IPv4 CIDR block\n" if !defined $prefix || $prefix > 32;

    return ( Provisioner::IPPool::int_to_address( Provisioner::IPPool::address_to_int($address) & mask($prefix) ), $prefix );
}

# The first and the last address of a CIDR block, as integers.
my sub range ($block) {
    return map { Provisioner::IPPool::address_to_int($_) } split /-/, ( Net::CIDR::cidr2range($block) )[0];
}

# How the CIDR block $block lies against the CIDR block $net, as one of the
# overlap constants of Net::IP.
my sub overlap ( $block, $net ) {
    my ( $inner, $outer ) = map { Net::IP->new($_) // die "'$_' is not an IPv4 CIDR block: " . Net::IP::Error() . "\n" } $block, $net;
    return $inner->overlaps($outer) // $IP_NO_OVERLAP;
}

# Whether every address of the CIDR block $block is in the CIDR block $net.
my sub within ( $block, $net ) {
    my $overlap = overlap( $block, $net );
    return $overlap == $IP_A_IN_B_OVERLAP || $overlap == $IP_IDENTICAL;
}

=head2 $range = dynamic_pool($subnet, $cidr, @blocks)

The part of the VPN subnet C<$subnet/$cidr> that the server hands out to a
client without an address of its own, as C<< { start => $ip, end => $ip } >>.
That is every host address of the subnet outside the CIDR blocks C<@blocks>,
except the first, which is the server.

Dies if a block is not inside the subnet, or holds the network address or the
address of the server, or if the blocks leave no address, or leave two ranges,
because C<ifconfig-pool> takes one.

=cut

sub dynamic_pool ( $subnet, $cidr, @blocks ) {
    my $net = join( '/', network("$subnet/$cidr") );
    my ( $first, $last ) = range($net);
    my @reserved = map { Provisioner::IPPool::int_to_address($_) } $first, $first + 1;

    my @taken;
    foreach my $block (@blocks) {
        die "The bin with $block routes through this openvpn server, so it must be inside its subnet $net\n"
          unless within( $block, $net );
        die "The bin with $block routes through this openvpn server, so it cannot hold @reserved, which are the network and the server\n"
          if Net::CIDR::cidrlookup( $block, map { "$_/32" } @reserved );
        @taken = Net::CIDR::cidradd( $block, @taken );
    }

    # The gaps between what the bins take, from the first address after the
    # server to the last before the broadcast.
    my @free;
    my $from = $first + 2;
    foreach my $span ( sort { $a->[0] <=> $b->[0] } map { [ range($_) ] } @taken ) {
        push @free, [ $from, $span->[0] - 1 ] if $span->[0] > $from;
        $from = $span->[1] + 1;
    }
    push @free, [ $from, $last - 1 ] if $from < $last;

    die "No available address to assign in the configured subnet ($net)!\n" unless @free;
    die "The bins that route through this openvpn server split $net in two, and openvpn hands out one range: put them at its top end\n"
      if @free > 1;

    return { start => Provisioner::IPPool::int_to_address( $free[0][0] ), end => Provisioner::IPPool::int_to_address( $free[0][1] ) };
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<cidr>, the prefix length of C<netmask>, for the firewall rules of the
VPN subnet.  Dies if C<netmask> is not a netmask.

Fills in C<routes> from every bin of C<ip_pool>: the two halves of each C<cidr>
block, then a C</32> for each of its C<addresses>, each route once.  A C</32>
block has no halves, so it goes as it is.  A route inside C<subnet> is left
out, because a bin there holds VPN clients.  See L</The networks that a client
reaches>.

Adds C<pushes>, each route as the C<network> and the C<netmask> that the
C<route> directive of OpenVPN takes, with the host bits of the network cleared.
Dies if a route is not an IPv4 CIDR block.

For the bins of C<ip_pool> whose C<via> is this domain, adds C<static_blocks>,
their networks, and C<ifconfig_pool>, the C<start> and C<end> of what is left of
C<subnet> for a client without an address of its own.  Dies if such a bin is
not inside C<subnet>, or leaves nothing of it, or leaves two ranges.  See
L</Static addresses>.

Dies if any other bin has an address in C<subnet>.  A bin with another C<via>
there means that two servers share the subnet.  A bin without C<via> there
holds addresses that this server also hands out.

=cut

=head2 %required = $recipe->required_recipes(%opts)

Requires C<cron>, which installs F<openvpn-refresh-crl.cron> and
F<openvpn-ca-expiry.cron> under F</etc/cron.d>.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    my %files = map { $_ => "$_.cron" } qw{openvpn-refresh-crl openvpn-ca-expiry};
    return ( cron => sub { return ( files => \%files ) } );
}

sub enrich {
    my ( $self, %opts ) = @_;

    my $vpn = eval { Net::CIDR::addrandmask2cidr( $opts{subnet}, $opts{netmask} ) } // die "The netmask $opts{netmask} of the VPN subnet is not a run of ones and then zeros\n";
    ( undef, $opts{cidr} ) = split m{/}, $vpn;

    my %bins   = Provisioner::IPPool::bins( $opts{ip_pool} // {} );
    my $domain = $opts{domain} // q{};
    foreach my $name ( sort keys %bins ) {
        my $via = $bins{$name}{via};
        next if defined $via && $via eq $domain;

        foreach my $block ( Provisioner::IPPool::blocks( $bins{$name} ) ) {
            next if overlap( $block, $vpn ) == $IP_NO_OVERLAP;
            die "ip_pool has $block in the bin $name, which routes through $via, but $block is in $vpn, the VPN subnet of $domain.  " . "Give the two openvpn servers different subnets.\n"
              if defined $via;
            die "ip_pool has $block in the bin $name, but $block is in $vpn, the VPN subnet of $domain, which hands out those addresses to its own clients.  " . "Move the bin out of $vpn.  If the bin holds the clients of $domain, give it via: $domain.\n";
        }
    }

    unless ( $opts{routes} ) {
        my @routes;
        foreach my $block ( map { Provisioner::IPPool::pool_items( $_->{cidr} ) } @bins{ sort keys %bins } ) {
            my ( $address, $prefix ) = network($block);
            if ( $prefix == 32 ) {
                push @routes, "$address/32";
                next;
            }

            my $half = 2**( 31 - $prefix );
            my $base = Provisioner::IPPool::address_to_int($address);
            push @routes, map { Provisioner::IPPool::int_to_address( $base + $_ * $half ) . '/' . ( $prefix + 1 ) } 0, 1;
        }
        push @routes, map { "$_/32" } Provisioner::IPPool::pool_items( $_->{addresses} ) for @bins{ sort keys %bins };

        # A bin inside the VPN subnet holds the clients themselves, which the
        # tunnel already reaches.
        my %seen;
        $opts{routes} = [ grep { !$seen{$_}++ && !within( $_, $vpn ) } @routes ];
    }

    my %static = Provisioner::IPPool::bins_via( $opts{ip_pool} // {}, $opts{domain} // q{} );
    if (%static) {
        my @blocks = map { Provisioner::IPPool::blocks($_) } @static{ sort keys %static };
        $opts{static_blocks} = \@blocks;
        $opts{ifconfig_pool} = dynamic_pool( $opts{subnet}, $opts{cidr}, @blocks );
    }

    $opts{pushes} = [
        map {
            my ( $address, $prefix ) = network($_);
            +{ network => $address, netmask => Provisioner::IPPool::int_to_address( mask($prefix) ) }
        } @{ $opts{routes} }
    ];

    return %opts;
}

=head2 %files = $recipe->issue_grant($grant, address => $address, server => $name)

The configuration that the server of C<$grant> issues for its client, at the
static C<$address>, as C<issue_grant> in L<Provisioner::Recipe> says.  C<$name>
is the server block that the client connects to, as C<openvpn-client-config>
takes it.  The file lands at F</etc/openvpn/client/CLIENT/issued.ovpn.b64>, in
base64, because an issued secret is one line.

=cut

sub issue_grant {
    my ( $self, $grant, %terms ) = @_;
    my $client = $grant->{client};
    return (
        "/etc/openvpn/client/$client/issued.ovpn.b64" => {
            issue => {
                guest   => $grant->{guest},
                command => "/usr/local/sbin/openvpn-client-config --address $terms{address} $client $terms{server} | base64 -w0",
            },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head2 %revocation = $recipe->revoke_grant($grant)

The revoke of the certificate of the client of C<$grant> by
C<openvpn-revoke-client>, which also frees its static address on the server, as
C<revoke_grant> in L<Provisioner::Recipe> says.  If the server is not up, the
revocation says to revoke the client there by hand before another one gets the
address, because two clients with one address cut each other off.

=cut

sub revoke_grant {
    my ( $self, $grant ) = @_;
    my $client = $grant->{client};
    return (
        command => "/usr/local/sbin/openvpn-revoke-client $client",
        doing   => "revoke the VPN certificate of $client",
        done    => "Revoked the VPN certificate of $client",
        stays   => "the certificate and the address of $client stay on it.  Run openvpn-revoke-client $client there before another client gets the address",
    );
}

sub template_files {
    my ($self) = @_;

    return (
        'openvpn.server.conf.tt'      => 'server.conf',
        'openvpn.stage-pki.tt'        => 'openvpn-stage-pki',
        'openvpn.client-config.tt'    => 'openvpn-client-config',
        'openvpn.revoke-client.tt'    => 'openvpn-revoke-client',
        'openvpn.list-clients.tt'     => 'openvpn-list-clients',
        'openvpn.refresh-crl.tt'      => 'openvpn-refresh-crl',
        'openvpn.refresh-crl.cron.tt' => 'openvpn-refresh-crl.cron',
        'openvpn.easyrsa.vars.tt'     => 'easyrsa.vars',
        'openvpn.ca-expiry.tt'        => 'openvpn-ca-expiry',
        'openvpn.ca-expiry.cron.tt'   => 'openvpn-ca-expiry.cron',

        # The ufw application profile.  This recipe renders it, because ufw
        # gets only rate_limits and not the port or the protocol.
        'openvpn.ufw.conf.tt' => 'openvpn_ufw.conf',
    );
}

=head2 $command = $recipe->static_clients_command()

The shell command that root runs on this server to list each client with a
static address.  It prints the name of the client, a tab, and the address, one
client to a line.  L<Provisioner::IPPool> runs it before it hands out an address
from a bin whose C<via> is this server.

=cut

sub static_clients_command {
    return '/usr/local/sbin/openvpn-list-clients --static';
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # The PKI with its CA.  It must arrive before the fragment asks easyrsa for
    # a CA, because a new CA is one that no existing client trusts.
    return (
        '/etc/openvpn/easy-rsa/pki' => { from => "$install_dir/$domain/openvpn/pki", owner => 'root:root' },

        # The static address of each client.  See DESCRIPTION.
        '/etc/openvpn/server/ccd' => { from => "$install_dir/$domain/openvpn/ccd", owner => 'root:root' },
    );
}

=head2 @commands = $recipe->remote_prepare($install_dir, $domain)

Returns C<openvpn-stage-pki>, so that the fetch gets the PKI as it is now and
not as it was at the last provision.

=cut

sub remote_prepare {
    return ('/usr/local/sbin/openvpn-stage-pki');
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # The staged copy of the PKI.  See DESCRIPTION for why it is a copy.
        '/etc/openvpn/pki-salvage/' => 'openvpn/pki/',
        '/etc/openvpn/ccd-salvage/' => 'openvpn/ccd/',
    );
}

sub tests {
    return qw{openvpn.tt};
}

1;
