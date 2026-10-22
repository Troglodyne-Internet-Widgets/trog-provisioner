package Provisioner::Recipe::edge;

#ABSTRACT: Proxy the public names of other guests to them, by name.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

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

=head2 %files = $recipe->client_secret($edge, $client, %opts)

The key that C<$edge> issues when it registers the names of the domain
C<$client>, at C<key_path> of C<$client>, as C<client_secret> in
L<Provisioner::Recipe> says.  C<%opts> has
C<< upstreams => { tls => $tls, http => $http } >> and
C<< names => \@names >>.

The command is F<scripts/edge_client> C<register>, which root runs on
C<$edge>.  C<$tls> and C<$http> are each an IPv4 address and a port, where
C<$edge> sends TLS and plain HTTP for C<@names>.  See L</Registration>.

=cut

sub client_secret {
    my ( $self, $edge, $client, %opts ) = @_;
    return (
        $self->key_path($client) => {
            issue => {
                guest   => $edge,
                command => join( q{ }, "$Provisioner::Vars::SCRIPT_DIR/edge_client register", $client, @{ $opts{upstreams} }{qw{tls http}}, @{ $opts{names} } ),
            },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head2 $command = $recipe->release_command($edge, $client)

The shell command that root runs on C<$edge> to release the names of
C<$client>: F<scripts/edge_client> C<release>.

=cut

sub release_command {
    my ( $self, $edge, $client ) = @_;
    return "$Provisioner::Vars::SCRIPT_DIR/edge_client release $client";
}

sub template_files {
    return (
        'edge.stream.conf.tt' => 'edge.stream.conf',
        'edge.http.conf.tt'   => 'edge.http.conf',
        'edge.ufw.conf.tt'    => 'edge_ufw.conf',
    );
}

sub tests {
    return qw{edge.tt};
}

1;
