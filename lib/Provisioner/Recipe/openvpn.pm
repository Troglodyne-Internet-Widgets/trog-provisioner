package Provisioner::Recipe::openvpn;

#ABSTRACT: Set up an OpenVPN server with an easy-rsa PKI.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Socket qw{inet_aton};

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

C<remote_files> names a staged copy, not the PKI itself.  The fragment writes it
at F</etc/openvpn/pki-salvage>.  The fetch reads the guest as root, so it can
read the real PKI.  Issue #98 decides whether the recipe names the real PKI.
The staged copy also keeps the copy that travels apart from the one that the
running VPN uses.

The staged copy belongs to the admin user and nobody else can read it.  The mail
recipe makes the same trade to salvage its DKIM keys.  The admin account can
read the CA private key.  The key travels into the data directory, and into any
backup of that directory.  That is the cost of a VPN that survives the loss of
its guest.

The copy is only as new as the last provision.  A client certificate that
somebody issues by hand after that is not in it until the next provision.  The
CA that signed it is in the copy, so the certificate continues to work.

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
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;
    $opts{cidr} = _netmask_to_cidr( $opts{netmask} );
    return %opts;
}

=head2 $prefix = _netmask_to_cidr($netmask)

Takes a dotted-quad C<netmask>, such as C<255.255.255.0>.  Returns the number of
bits that are set in it, such as C<24>.  The firewall rules use it as the prefix
length of the VPN subnet.

Returns 0 for a C<netmask> that is empty, undefined or not a dotted quad.  It does
not die.

=cut

sub _netmask_to_cidr {
    my ($mask) = @_;

    # Test the format first, because inet_aton() resolves anything else as a
    # hostname.
    return 0 unless $mask && $mask =~ m{^\d{1,3}(?:\.\d{1,3}){3}$};
    my $packed = inet_aton($mask) or return 0;
    return unpack( '%32b*', $packed );
}

sub template_files {
    my ($self) = @_;

    return (
        'openvpn.server.conf.tt' => 'server.conf',

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
