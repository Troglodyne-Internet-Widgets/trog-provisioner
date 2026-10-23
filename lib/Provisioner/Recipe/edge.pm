package Provisioner::Recipe::edge;

#ABSTRACT: Proxy the public names of other guests to them, by name.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use File::Slurper();
use File::Temp();

use Provisioner::IPPool();
use Provisioner::Utils();
use Provisioner::Vars();

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::edge

=head2 SYNOPSIS

    edge.somedomain:
        edge:

    internal.somedomain:
        nginx:
            edge: edge.somedomain
            public_names:
                shop.internal.somedomain: internal.somedomain

=head2 DESCRIPTION

Makes this guest the front of the guests that name it as their C<edge>, for
the internet.  The public names of those guests point at this guest.

A TLS connection on 443 goes to the guest that registered its SNI name, on its
port 8443, with the PROXY protocol.  The connection stays encrypted, so the
guest keeps its own certificate, and this guest holds no key of it.  A request
on 80 goes to the guest that registered its C<Host> header, on its port 8080,
with the address of the client in C<X-Forwarded-For>.  From outside, a name
that no guest registered gets no reply, except a name of a vhost of this guest
on 80.  See L</Ports>.

See L<Provisioner::Recipe::nginx/Names that reach the guest through a proxy>
for what the guest does on those ports.

=head2 Registration

Nothing in the configuration of this guest names the guests behind it.  Each
guest registers its own names when it is built, through C<edge_client
register>, which C<bin/provision> runs here as root.  C<bin/destroy> runs
C<edge_client release> when the guest goes away.  See F<scripts/edge_client>.

So this guest is built first, and a guest that names it fails to build while it
is down.  A rebuild of this guest does not need the guests behind it, because
the registrations in F</etc/nginx/edge.d> are salvaged.

Two guests cannot register one name.  The second one fails to build, and the
error names the domain that holds it.

=head2 Bans

A guest behind this edge sees the address of each client, so its fail2ban
finds the abuse.  But a ban there blocks nothing, because the packets come from
this guest.  So the guest also sends each ban here, and this guest drops the
address.  See L<Provisioner::Recipe::nginx/Bans through the edge>.

When C<edge_client register> issues the key of a domain, it authorizes the key
for root in F</etc/nginx/edge.d/authorized_keys.root>, which sshd reads beside
the keys of root.  The key runs only F<scripts/edge_ban> for that domain, and
only from the address of its guest.  C<edge_ban> adds the address to the ipset
C<edge-bans> for the time of the ban, or removes it.  The registrations and
their keys are salvaged together, so a rebuild keeps both.

F</etc/ufw/after.init.d/edge-bans> drops every packet from an address in the
set to port 80 and to C<tls_port>, each time ufw loads.  See
L<Provisioner::Recipe::ufw/Rules that ufw cannot write>.  ssh stays open to a
banned address, so a ban that a guest sends cannot lock the operator out of
the edge.  When ufw unloads, the set goes to F</var/lib/edge-bans/saved> with
the time that each ban has left, and it comes back when ufw loads.

The guests pin the ed25519 host key of this guest, so it comes from the secret
store, and a rebuild keeps it.

=head2 Ports

The stream proxy listens on C<tls_port>, and ufw forwards 443 there for every
connection that reaches the guest from outside.  A connection that the guest
makes to itself is not forwarded.  So nginx can still serve the vhosts of this
guest on 443 locally, such as the vhost that the letsencrypt guest test asks
for its certificate.  From outside, a name that no guest registered gets no TLS
handshake, the names of this guest included.

On 80, the server of this recipe is the default server of nginx.  A vhost of
this guest on 80 still answers for its own names, because nginx chooses among
the servers of one port by the C<Host> header.  This recipe takes the default
site of the nginx package away, which would be a second default server.

=cut

sub args {
    return (
        properties => {
            tls_port => {
                type        => 'integer',
                minimum     => 1024,
                maximum     => 65535,
                default     => 4443,
                description => 'The port of the stream proxy, where ufw forwards 443 from outside.  See "Ports".',
            },
        },
    );
}

# Defaulted here as well as in args, because required_recipes and rate_limits
# run before validation.
my sub tls_port (%opts) {
    return $opts{tls_port} // 4443;
}

sub required_recipes {
    return (
        nginx => sub { return () },
        ufw   => sub {
            my (%opts) = @_;
            return ( port_forwards => [ { from => 443, to => tls_port(%opts) } ] );
        },
    );
}

=head2 %limits = $recipe->rate_limits(%opts)

The limit of 443 for C<tls_port>, because the forward happens before the limit
counts a connection.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;
    return ( tls_port(%opts) => 1024 );
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

F</etc/nginx/edge.d>, which holds the registrations.  Without it, a rebuilt
edge proxies nothing until each guest behind it is built again.

=cut

sub remote_files {
    return ( '/etc/nginx/edge.d/' => 'edge.d/' );
}

=head2 %restores = $recipe->restores(%opts)

The salvage of F</etc/nginx/edge.d> goes back there.

=cut

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};
    return ( '/etc/nginx/edge.d' => { from => "$install_dir/$domain/edge.d", owner => 'root:root' } );
}

=head2 $path = $recipe->key_path($domain)

Where the key that this guest issues for C<$domain> is, on the guest of
C<$domain>.

=cut

sub key_path {
    my ( $self, $domain ) = @_;
    return "/etc/fail2ban/edge/$domain.key.b64";
}

=head2 $path = $recipe->host_key_path($domain)

Where the public host key of the edge is, on the guest of C<$domain>, in
base64.

=cut

sub host_key_path {
    my ( $self, $domain ) = @_;
    return "/etc/fail2ban/edge/$domain.host.b64";
}

=head2 $address = $recipe->address($edge)

The address at which the guests reach the guest C<$edge>: its address in a bin
other than C<guests> of the address pool, which is the tunnel of an edge that
is a client of the VPN, and otherwise its address in C<guests>.  Dies when it
has neither, or more than one of the first kind.

=cut

sub address {
    my ( $self, $edge ) = @_;
    my $held = Provisioner::IPPool::holdings($edge);
    my @vpn  = grep { $_ ne $Provisioner::IPPool::GUESTS } sort keys %$held;

    die "edge: $edge has an address in each of " . join( ', ', @vpn ) . ", so the guests behind it cannot tell which one reaches it.\n" if @vpn > 1;
    my $address = @vpn ? $held->{ $vpn[0] } : $held->{$Provisioner::IPPool::GUESTS};
    die "edge: $edge has no address in " . Provisioner::IPPool::db_path() . ", so the guests behind it cannot send it their bans.\n" unless defined $address;
    return $address;
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain, %opts)

The ed25519 host key of sshd, which the guests behind this edge pin.  See
L</Bans>.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/etc/ssh/ssh_host_ed25519_key' => {
            ref      => "secret:edge/$domain-ssh-host-key/password",
            generate => sub {
                my $path = File::Temp::tempdir( CLEANUP => 1 ) . '/host_key';
                Provisioner::Utils::write_ssh_keypair( $path, Ed25519 => 256, "root\@$domain" );

                # bin/provision adds a newline, and ssh-keygen refuses a key
                # that ends with a blank line.
                chomp( my $key = File::Slurper::read_binary($path) );
                return $key;
            },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head2 %files = $recipe->issue_grant($grant, %terms)

The key that the edge issues when it registers the names of the client of
C<$grant>, at C<key_path> of the client, as C<issue_grant> in
L<Provisioner::Recipe> says.  Also the public host key of the edge, at
C<host_key_path>, which the client pins.  C<%terms> has
C<< upstreams => { tls => $tls, http => $http } >> and
C<< names => \@names >>.

The command is F<scripts/edge_client> C<register>, which root runs on the edge.
C<$tls> and C<$http> are each an IPv4 address and a port, where the edge sends
TLS and plain HTTP for C<@names>.  See L</Registration>.

=cut

sub issue_grant {
    my ( $self, $grant, %terms ) = @_;
    my $client = $grant->{client};
    return (
        $self->key_path($client) => {
            issue => {
                guest   => $grant->{guest},
                command => join( q{ }, "$Provisioner::Vars::SCRIPT_DIR/edge_client register", $client, @{ $terms{upstreams} }{qw{tls http}}, @{ $terms{names} } ),
            },
            owner => 'root:root',
            mode  => '0600',
        },
        $self->host_key_path($client) => {
            issue => { guest => $grant->{guest}, command => 'base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub' },
            owner => 'root:root',
            mode  => '0644',
        },
    );
}

=head2 %revocation = $recipe->revoke_grant($grant)

The release of the names of the client of C<$grant>, by F<scripts/edge_client>
C<release>, as C<revoke_grant> in L<Provisioner::Recipe> says.  If the edge is
not up, the revocation says to run the command there by hand before another
guest gets the address, because the edge sends the names to whatever answers at
it.

=cut

sub revoke_grant {
    my ( $self, $grant ) = @_;
    my $client  = $grant->{client};
    my $command = "$Provisioner::Vars::SCRIPT_DIR/edge_client release $client";
    return (
        command => $command,
        doing   => "release the public names of $client",
        done    => "Released the public names of $client",
        stays   => "it still sends the public names of $client to its old address.  Run $command there before another guest gets the address",
    );
}

sub template_files {
    return (
        'edge.stream.conf.tt' => 'edge.stream.conf',
        'edge.http.conf.tt'   => 'edge.http.conf',
        'edge.ufw.conf.tt'    => 'edge_ufw.conf',
        'edge.sshd.tt'        => 'edge.sshd.conf',
        'edge.bans.tt'        => 'edge.bans',
    );
}

sub tests {
    return qw{edge.tt};
}

1;
