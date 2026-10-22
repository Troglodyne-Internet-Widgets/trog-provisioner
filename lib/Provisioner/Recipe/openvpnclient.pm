package Provisioner::Recipe::openvpnclient;

#ABSTRACT: Connect the host to an OpenVPN server as a client.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Digest::SHA();

use Provisioner::Cookbook();
use Provisioner::IPPool();

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

The guest gets its certificates in one of two ways.  With C<issue_from>, the
VPN server issues them when the guest is built, with a static address.  See
L</A client with a static address>.  With C<cert_dir>, they come from a
directory on this machine.

For C<cert_dir>, make the client certificates (ca.crt, client.crt, client.key,
ta.key) on the VPN server with easy-rsa first.  Put them in cert_dir on the machine that runs this
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

=head3 A client with a static address

    somedomain:
        openvpnclient:
            server: vpn.test.test
            issue_from: vpn.test.test

C<issue_from> names the guest that runs L<Provisioner::Recipe::openvpn>.  A bin
of the C<ip_pool> must name that guest in C<via>.  C<bin/new_config> gives this
domain an address from that bin, and C<bin/provision> asks the server for a
configuration with C<openvpn-client-config --address>, before the makefile
starts.  The server must be up first.  So this domain always connects with that
address, and the guests reach it there.  See
L<Provisioner::Recipe::openvpn/Static addresses>.

The configuration arrives in base64 on one line, because a secret that another
guest issues is one line.  The fragment splits it into the four files that a
C<cert_dir> holds.  The port, the protocol and the cipher of this recipe must
still match the server.

C<bin/destroy> revokes the certificate on the server, which frees the address.
A rebuild gets the same certificate again, because the server keeps it.

=head3 Several tunnels on one guest

A guest can hold two domains that connect to two different VPNs, and openvpn
supports that directly.  C<openvpn-client@> is a template unit with one instance
per tunnel.  Each instance reads F</etc/openvpn/client/E<lt>nameE<gt>.conf>.

So this recipe names everything for the domain: the instance, the configuration,
the certificate directory, the log and the interface.  Two domains share only
the openvpn package.  That is why this recipe can share a machine with another
instance of itself, when most recipes cannot.

=head3 Why nothing here is salvaged

C<cert_dir> on the machine that runs this tool keeps these certificates, or the
server of C<issue_from> does.  Every run copies them over the copy on the
guest.  So a rebuilt guest needs nothing from the guest before it.

That is why this recipe declares no C<remote_files>.  A salvage of
F</etc/openvpn/client> takes a client key, which the fetch cannot read without a
staged copy made for it.  It also puts a second copy of that key in the domain
directory and in every backup of that directory.  C<cert_dir> already holds the
only copy that must exist.

=cut

sub args {
    return (
        required   => [qw{server}],
        oneOf      => [ map { { required => [$_] } } qw{cert_dir issue_from} ],
        properties => {

            # A name or an address, because it goes into a command that root
            # runs on the server of issue_from.
            server   => { type => 'string', pattern => q{\A[A-Za-z0-9][A-Za-z0-9.-]*\z} },
            cert_dir => { type => 'string' },

            issue_from => {
                type        => 'string',
                description => 'The guest that runs the openvpn server, which issues the certificates of this domain and its static address when it is built.  A bin of ip_pool must name it in via.  The alternative to cert_dir.',
            },
            port   => { type => 'integer', minimum => 1024,          default => 1194 },
            proto  => { type => 'string',  enum    => [qw{udp tcp}], default => 'udp' },
            cipher => { type => 'string',  default => 'AES-256-GCM' },

            device => {
                type        => 'string',
                pattern     => q{\A[a-z][a-z\d_-]{0,14}\z},
                description => 'The tunnel interface this domain gets.  No default is declared here because it comes from the domain: two tunnels on one guest cannot share an interface, and the kernel will not take a name longer than fifteen characters.  Name one to pin it.',
            },
        },
    );
}

# The name and the block of the one bin of $pool that routes through $issuer.
my sub bin_of ( $pool, $issuer ) {
    my %via   = Provisioner::IPPool::bins_via( $pool // {}, $issuer );
    my @names = sort keys %via;
    die "openvpnclient takes its address from the bin of ip_pool whose via is $issuer, and ip_pool has " . ( @names ? 'several: ' . join( ', ', @names ) : 'none' ) . "\n"
      unless @names == 1;
    return ( $names[0], $via{ $names[0] } );
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

With C<issue_from>, it also sets C<address_blocks>, the networks of the bin
that the address of this domain comes from.  Dies unless one bin of C<ip_pool>
names C<issue_from> in C<via>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{device} //= 'tun-' . substr( Digest::SHA::sha256_hex( $opts{domain} // q{} ), 0, 8 );

    if ( defined $opts{issue_from} ) {
        my ( undef, $bin ) = bin_of( $opts{ip_pool}, $opts{issue_from} );
        $opts{address_blocks} = [ Provisioner::IPPool::blocks($bin) ];
    }

    return %opts;
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain, %opts)

With C<issue_from>, the configuration of this domain, which the server of
C<issue_from> issues with the static address of the domain.  The address comes
from the bin of the C<ip_pool> of this installation whose C<via> is that
server.  This assigns it, as C<bin/new_config> assigns the address of a guest:
a domain that has one keeps it.  Without C<issue_from>, nothing.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain, %opts ) = @_;
    my $issuer = $opts{issue_from};
    return () unless defined $issuer;

    my $pool    = Provisioner::Cookbook->global_config($domain)->{ip_pool};
    my ($bin)   = bin_of( $pool, $issuer );
    my $address = Provisioner::IPPool::assign( $domain, $pool, $bin );

    return Provisioner::Cookbook->load('openvpn')->client_secret( $issuer, $domain, address => $address, server => $opts{server} );
}

=head2 @releases = $recipe->releases($domain)

With C<issue_from>, the revoke of the certificate of C<$domain> on that server,
which also frees the static address that the server gave it, as C<releases> in
L<Provisioner::Recipe> says.  If the server is not up, the release says to
revoke the client there by hand before another one gets the address, because
two clients with one address cut each other off.

=cut

sub releases {
    my ( $self, $domain ) = @_;

    my $issuer = ( Provisioner::Cookbook->domain_config($domain)->{ $self->recipe_name } // {} )->{issue_from};
    return if !defined $issuer;

    return {
        guest   => $issuer,
        command => Provisioner::Cookbook->load('openvpn')->release_command( $issuer, $domain ),
        doing   => "revoke the VPN certificate of $domain",
        done    => "Revoked the VPN certificate of $domain",
        stays   => "the certificate and the address of $domain stay on it.  Run openvpn-revoke-client $domain there before another client gets the address",
    };
}

sub template_files {
    my ($self) = @_;

    return (
        'openvpnclient.client.conf.tt' => 'client.conf',
    );
}

sub fetch_sources {
    my ( $self, %opts ) = @_;
    return defined $opts{cert_dir} ? ( cert_dir => $opts{cert_dir} ) : ();
}

sub tests {
    return qw{openvpnclient.tt};
}

1;
