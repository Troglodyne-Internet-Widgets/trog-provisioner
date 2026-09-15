package Provisioner::Recipe::openvpnclient;

#ABSTRACT: Connect the host to an OpenVPN server as a client.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Digest::SHA();

=head1 Provisioner::Recipe::openvpnclient

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        openvpnclient:
            order: A
            server: vpn.example.test
            cert_dir: /opt/vpn-certs/somedomain
            port: 1194
            proto: udp
            cipher: AES-256-GCM

=head2 DESCRIPTION

Connects this host to an OpenVPN server as a client.

Client certificates (ca.crt, client.crt, client.key, ta.key) must be
pre-generated on the VPN server via easy-rsa and placed in cert_dir on the
machine running this tool.  The recipe rsyncs them to the provisioned host as
the C<transfer_user>, by address -- the same way the data recipe fetches a
domain's payload, and for the same reason: this runs before the guest's DNS is
any use.

Because the VPN tunnel is brought up during provisioning (not deferred to
postrun), any recipe that needs connectivity through the tunnel must run after
this one.  Recipe execution order is determined by the C<order:> key  set
this recipe's order to a value that sorts before any recipe depending on the
tunnel (e.g. C<order: A>).

=head3 Several tunnels on one guest

A guest can hold two domains connecting to two different VPNs, and openvpn
supports that directly: C<openvpn-client@> is a template unit, one instance per
tunnel, each reading F</etc/openvpn/client/E<lt>nameE<gt>.conf>.

So everything here is named for the domain -- the instance, the configuration,
the directory the certificates land in, the log, and the interface.  Two domains
share nothing but the openvpn package, which is what lets this recipe sit on a
machine with another of its kind when most of its neighbours cannot.

=head3 Why nothing here is salvaged

C<cert_dir> on the hypervisor is where these certificates are kept, and they are
rsynced over the guest's copy on every run -- so a rebuilt guest needs nothing
brought back off the last one.

Which is the whole reason there is no C<remote_files> here.  Salvaging
F</etc/openvpn/client> would take a client key, which the fetch cannot read
anyway without a staged copy made for it, and put a second copy of it in the
domain directory and in every backup taken of that.  The hypervisor already
holds the only copy that has to exist.

=cut

sub args {
    return (
        required   => [qw{server cert_dir}],
        properties => {
            server   => { type => 'string' },
            cert_dir => { type => 'string' },
            port     => { type => 'integer', minimum => 1024,          default => 1194 },
            proto    => { type => 'string',  enum    => [qw{udp tcp}], default => 'udp' },
            cipher   => { type => 'string',  default => 'AES-256-GCM' },

            device => {
                type        => 'string',
                pattern     => q{\A[a-z][a-z\d_-]{0,14}\z},
                description => 'The tunnel interface this domain gets.  No default is declared here because it comes from the domain: two tunnels on one guest cannot share an interface, and the kernel will not take a name longer than fifteen characters.  Name one to pin it.',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

C<device> comes from the domain.  Left to itself openvpn hands out C<tun0>,
C<tun1> and so on in start order, which says nothing about which tunnel is which
and leaves the fragment no name to wait on.

Hashed rather than spelled out, because an interface name stops at fifteen
characters and a domain is routinely longer -- the same bargain
L<Trog::HV::Libvirt/guest_mac> makes for a MAC address, and with the same two
properties: one domain gets the same interface on every rebuild, and two domains
do not collide.  A domain naming its own keeps it.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{device} //= 'tun-' . substr( Digest::SHA::sha256_hex( $opts{domain} // q{} ), 0, 8 );

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'openvpnclient.client.conf.tt' => 'client.conf',
    );
}

sub fetch_sources {
    my ( $self, %opts ) = @_;
    return defined $opts{cert_dir} ? ( $opts{cert_dir} ) : ();
}

sub tests {
    return qw{openvpnclient.tt};
}

1;
