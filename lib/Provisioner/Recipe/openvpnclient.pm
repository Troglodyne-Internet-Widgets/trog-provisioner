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
            server: vpn.example.test
            cert_dir: /opt/vpn-certs/somedomain
            port: 1194
            proto: udp
            cipher: AES-256-GCM

=head2 DESCRIPTION

Connects this host to an OpenVPN server as a client.

Make the client certificates (ca.crt, client.crt, client.key, ta.key) on the VPN
server with easy-rsa first.  Put them in cert_dir on the machine that runs this
tool.  The guest fetches them from that machine with rsync, as the
C<transfer_user> and by address.  The data recipe fetches the payload of a domain
the same way, for the same reason.  The DNS of the guest does not work yet when
this runs.

The tunnel comes up during the provision, not in the postrun.  So it is there
for every target that runs after the target of this recipe.

A recipe cannot ask for that order.  Nothing names a position in the build, and
a recipe that requires this one puts it B<after> itself.  If a recipe cannot
work without the tunnel, it must wait for the interface in its own fragment.
C<ssl.get_cert> waits in the same way for the server that answers its challenge.

=head3 Several tunnels on one guest

A guest can hold two domains that connect to two different VPNs, and openvpn
supports that directly.  C<openvpn-client@> is a template unit with one instance
per tunnel.  Each instance reads F</etc/openvpn/client/E<lt>nameE<gt>.conf>.

So this recipe names everything for the domain: the instance, the configuration,
the certificate directory, the log and the interface.  Two domains share only
the openvpn package.  That is why this recipe can share a machine with another
instance of itself, when most recipes cannot.

=head3 Why nothing here is salvaged

C<cert_dir> on the machine that runs this tool keeps these certificates.  Every
run copies them over the copy on the guest.  So a rebuilt guest needs nothing
from the guest before it.

That is why this recipe declares no C<remote_files>.  A salvage of
F</etc/openvpn/client> takes a client key, which the fetch cannot read without a
staged copy made for it.  It also puts a second copy of that key in the domain
directory and in every backup of that directory.  C<cert_dir> already holds the
only copy that must exist.

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

Takes the options of the recipe and returns them with C<device> set.  If the
domain names its own C<device>, it keeps it.  If not, the name comes from a hash
of the domain.

Without a name, openvpn hands out C<tun0>, C<tun1> and so on in start order.
Those names do not say which tunnel is which, and the fragment has no name to
wait on.

The name is a hash, not the domain, because the kernel limits an interface name
to fifteen characters.  A domain is often longer.  L<Trog::HV::Libvirt/guest_mac>
makes the same trade for a MAC address, with the same two properties.  One
domain gets the same interface on every rebuild, and two domains do not collide.

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
