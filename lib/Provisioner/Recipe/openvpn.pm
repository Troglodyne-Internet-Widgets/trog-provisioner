package Provisioner::Recipe::openvpn;

#ABSTRACT: Set up an OpenVPN server with an easy-rsa PKI.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Socket qw{inet_aton inet_ntoa};

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
block goes as its two halves, and each item of C<addresses> goes as a C</32>.
Without either, the server pushes no route.

The halves are for a client on a home network with the same numbers, such as
C<192.168.1.0/24>, the default of many home routers.  The client then has two
routes to the addresses of the guests, and the longer prefix wins.  A half is
longer than the home network, so traffic to a guest goes through the tunnel.

The cost is that the client cannot reach its own home network while it is
connected, for example its printer or its router, if that network has the same
numbers.  Its traffic for those addresses goes into the tunnel too.  If that
matters for a client, give C<routes> a C</32> for each guest, which takes only
those addresses away from the home network.

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

=head3 Taking a client away

    openvpn-revoke-client NAME

This revokes the certificate of C<NAME>, signs a new revocation list, and gives
the list to the server.  openvpn reads the list at each TLS handshake, so a new
connection from C<NAME> fails at once.  A client that is connected keeps its
tunnel until its next renegotiation, which openvpn does each hour.

A revocation list has an expiry, and easyrsa sets it to 180 days after it
signs.  An expired list stops B<every> client, because openvpn then refuses all
certificates.  So C<openvpn-refresh-crl> signs it again on each provision and
from cron each day.  The guest test fails when less than 30 days are left.

Run C<easyrsa revoke> through C<openvpn-revoke-client>, not by itself.  Alone,
it changes the index of the CA and not the list that the server reads.

=head3 Which clients there are

    openvpn-list-clients [--all]

This lists each name that can connect, when its certificate expires, and its
tunnel address if it is connected now.  C<--all> also lists the revoked and the
expired certificates.  The script reads the index of the CA and the status file
of the server, which the server rewrites each minute.

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
    my $packed = defined $prefix && $prefix <= 32 && inet_aton($address);
    die "'$block' is not an IPv4 CIDR block\n" unless $packed;

    return ( inet_ntoa( pack( 'N', unpack( 'N', $packed ) & mask($prefix) ) ), $prefix );
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<cidr>, the prefix length of C<netmask>, for the firewall rules of the
VPN subnet.

Fills in C<routes> from C<ip_pool>: the two halves of each C<cidr> block, then a
C</32> for each of its C<addresses>, each route once.  A C</32> block has no
halves, so it goes as it is.  See L</The networks that a client reaches>.

Adds C<pushes>, each route as the C<network> and the C<netmask> that the
C<route> directive of OpenVPN takes, with the host bits of the network cleared.
Dies if a route is not an IPv4 CIDR block.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    # The schema makes netmask an IPv4 address, so inet_aton resolves no name.
    $opts{cidr} = unpack( '%32b*', inet_aton( $opts{netmask} ) );

    unless ( $opts{routes} ) {
        my $pool = $opts{ip_pool} // {};
        my @routes;
        foreach my $block ( Provisioner::IPPool::pool_items( $pool->{cidr} ) ) {
            my ( $address, $prefix ) = network($block);
            if ( $prefix == 32 ) {
                push @routes, "$address/32";
                next;
            }

            my $half = 2**( 31 - $prefix );
            my $base = unpack( 'N', inet_aton($address) );
            push @routes, map { inet_ntoa( pack( 'N', $base + $_ * $half ) ) . '/' . ( $prefix + 1 ) } 0, 1;
        }
        push @routes, map { "$_/32" } Provisioner::IPPool::pool_items( $pool->{addresses} );

        my %seen;
        $opts{routes} = [ grep { !$seen{$_}++ } @routes ];
    }

    $opts{pushes} = [
        map {
            my ( $address, $prefix ) = network($_);
            +{ network => $address, netmask => inet_ntoa( pack( 'N', mask($prefix) ) ) }
        } @{ $opts{routes} }
    ];

    return %opts;
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

        # The ufw application profile.  This recipe renders it, because ufw
        # gets only rate_limits and not the port or the protocol.
        'openvpn.ufw.conf.tt' => 'openvpn_ufw.conf',
    );
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # The PKI with its CA.  It must arrive before the fragment asks easyrsa for
    # a CA, because a new CA is one that no existing client trusts.
    return ( '/etc/openvpn/easy-rsa/pki' => { from => "$install_dir/$domain/openvpn/pki", owner => 'root:root' } );
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
    );
}

sub tests {
    return qw{openvpn.tt};
}

1;
