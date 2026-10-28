package Provisioner::Recipe::openvpnclient;

#ABSTRACT: Connect the host to an OpenVPN server as a client.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Digest::SHA();
use List::Util();

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

Such a client also gets the guests of this installation by name.  The fragment
writes each guest that the ip pool assigns an address to into F</etc/hosts>,
with that address, in one block that names this domain.  A rebuild replaces
the block.  So the client finds the guests that it reaches through the tunnel
with no DNS server that knows them, wherever it is built.  A guest added after
this one is not in the block until this one is rebuilt.  A client with
C<cert_dir> connects to a server that this installation does not run, so it
gets no block.

C<bin/destroy> revokes the certificate on the server, which frees the address.
A rebuild gets the same certificate again, because the server keeps it.

=head3 A client on the same network as its server

You can build a client on the same network as the VPN server, for example on
a hypervisor beside it.  You add nothing to the configuration for this.  The
client reaches the other guests directly on that network.  It still gets its
address on the tunnel, and the other clients of the server reach it there.

C<bin/new_config> decides this when it builds the guest.  It asks the
hypervisors which network the guest and the server are on.  If the guest
moves to another network, build it again, and it then sends its traffic for
the guests through the tunnel.

The reason is the routes that the server pushes.  They must win over a home
network with the same numbers on a laptop, so they are longer than that
network.  See L<Provisioner::Recipe::openvpn/The networks that a client
reaches>.  On the network of the server, they also win over the route of the
guest to its own network.  So a client there ignores every route that the
server pushes.

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

It sets C<same_network_as_server> when the server, the guest of C<issue_from>
or of C<server>, is in C<network_peers>.  See L</A client on the same network
as its server>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{device} //= 'tun-' . substr( Digest::SHA::sha256_hex( $opts{domain} // q{} ), 0, 8 );

    if ( defined $opts{issue_from} ) {
        my ( undef, $bin ) = bin_of( $opts{ip_pool}, $opts{issue_from} );
        $opts{address_blocks} = [ Provisioner::IPPool::blocks($bin) ];
    }

    my %peer = map { $_ => 1 } @{ $opts{network_peers} // [] };
    $opts{same_network_as_server} = ( List::Util::any { $peer{$_} } $self->joins_network_of(%opts) ) ? 1 : 0;

    return %opts;
}

=head2 @grants = $recipe->grants($domain, %opts)

With C<issue_from>, the certificate and the static address that that server
issues to C<$domain>, as C<grants> in L<Provisioner::Recipe> says.  See
L<Provisioner::Recipe::openvpn/issue_grant>.  Without it, nothing.

=cut

sub grants {
    my ( $self, $domain, %opts ) = @_;
    my $issuer = $opts{issue_from};
    return () unless defined $issuer;

    return { recipe => 'openvpn', guest => $issuer, client => $domain };
}

=head2 @domains = $recipe->joins_network_of(%opts)

The guest of C<issue_from> and of C<server>, as C<joins_network_of> in
L<Provisioner::Recipe> says.  The server routes its clients to the network that
it is on, and the client reaches the server by its public name.  So a guest
behind it can go on a hypervisor of another network.

=cut

sub joins_network_of {
    my ( $self, %opts ) = @_;
    return List::Util::uniq( grep { defined && $_ ne q{} } @opts{qw{issue_from server}} );
}

=head2 %terms = $recipe->grant_terms($grant, %opts)

The static address of the client of C<$grant> and the C<server> block that it
connects to, as L<Provisioner::Recipe::openvpn/issue_grant> takes them.  The
address comes from the bin of the C<ip_pool> of this installation whose C<via>
is the server.  This assigns it, as C<bin/new_config> assigns the address of a
guest: a domain that has one keeps it.

=cut

sub grant_terms {
    my ( $self, $grant, %opts ) = @_;
    my $domain = $grant->{client};

    my $pool = Provisioner::Cookbook->global_config($domain)->{ip_pool};
    my ($bin) = bin_of( $pool, $grant->{guest} );
    return ( address => Provisioner::IPPool::assign( $domain, $pool, $bin ), server => $opts{server} );
}

sub template_files {
    my ($self) = @_;

    return (
        'openvpnclient.client.conf.tt' => 'client.conf',
        'openvpnclient.hosts.tt'       => 'vpn.hosts',
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
