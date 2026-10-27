package Provisioner::Recipe::nginxrelay;

#ABSTRACT: Proxy the public names of other guests to them, by name.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Provisioner::Vars();

use parent qw{Provisioner::RelayRecipe};

=head1 Provisioner::Recipe::nginxrelay

=head2 SYNOPSIS

    relay.somedomain:
        nginxrelay:

    internal.somedomain:
        nginx:
            relay: relay.somedomain
            public_names:
                shop.internal.somedomain: internal.somedomain

=head2 DESCRIPTION

Makes this guest the front of the guests that name it as their C<relay>, for
the web of the internet.  The public names of those guests point at this
guest.  The mail of those guests is the business of
L<Provisioner::Recipe::mailrelay>, which a guest runs beside this one or
without it.

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
guest registers its own names when it is built, through C<nginxrelay_client
register>, which C<bin/provision> runs here as root.  C<bin/destroy> runs
C<nginxrelay_client release> when the guest goes away.  See
F<scripts/nginxrelay_client>.

So this guest is built first, and a guest that names it fails to build while it
is down.  A rebuild of this guest does not need the guests behind it, because
the registrations in F</etc/nginx/nginxrelay.d> are salvaged.

Two guests cannot register one name.  The second one fails to build, and the
error names the domain that holds it.

=head2 Bans

A guest behind this relay sends its bans here, as
L<Provisioner::RelayRecipe/Bans> says, and this guest drops the address on 80
and on C<tls_port>.  C<nginxrelay_client register> issues the key of each
domain, which F</etc/nginx/nginxrelay.d> keeps.  See
L<Provisioner::Recipe::nginx/Bans through the relay> for what the guest does.

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

F</etc/nginx/nginxrelay.d>, which holds the registrations.  Without it, a
rebuilt relay proxies nothing until each guest behind it is built again.

=cut

sub remote_files {
    return ( '/etc/nginx/nginxrelay.d/' => 'nginxrelay.d/' );
}

=head2 %restores = $recipe->restores(%opts)

The salvage of F</etc/nginx/nginxrelay.d> goes back there.

=cut

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};
    return ( '/etc/nginx/nginxrelay.d' => { from => "$install_dir/$domain/nginxrelay.d", owner => 'root:root' } );
}

=head2 $dir = $recipe->relay_dir()

F</etc/nginx/nginxrelay.d>, which holds the registrations and the ban keys.
See L<Provisioner::RelayRecipe>.

=cut

sub relay_dir {
    return '/etc/nginx/nginxrelay.d';
}

=head2 @ports = $recipe->banned_ports(%opts)

80 and C<tls_port>, where this guest proxies.  The ban closes C<tls_port> and
not 443, because the forward comes first.

=cut

sub banned_ports {
    my ( $self, %opts ) = @_;
    return ( 80, tls_port(%opts) );
}

=head2 %files = $recipe->registration_files($grant, %terms)

The ban key that the relay issues when it registers the names of the client of
C<$grant>, at C<key_path> of the client.  L<Provisioner::RelayRecipe/issue_grant>
adds the host key of the relay.  C<%terms> has
C<< upstreams => { tls => $tls, http => $http } >> and
C<< names => \@names >>.

The command is F<scripts/nginxrelay_client> C<register>, which root runs on the
relay.  C<$tls> and C<$http> are each an IPv4 address and a port, where the
relay sends TLS and plain HTTP for C<@names>.  See L</Registration>.

=cut

sub registration_files {
    my ( $self, $grant, %terms ) = @_;
    my $client = $grant->{client};

    return (
        $self->key_path($client) => {
            issue => {
                guest   => $grant->{guest},
                command => join( q{ }, "$Provisioner::Vars::SCRIPT_DIR/nginxrelay_client register", $client, @{ $terms{upstreams} }{qw{tls http}}, @{ $terms{names} } ),
            },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head2 %revocation = $recipe->revoke_grant($grant)

The release of the names of the client of C<$grant>, by
F<scripts/nginxrelay_client> C<release>, as C<revoke_grant> in
L<Provisioner::Recipe> says.  If the relay is not up, the revocation says to
run the command there by hand before another guest gets the address, because
the relay sends the names to whatever answers at it.

=cut

sub revoke_grant {
    my ( $self, $grant ) = @_;
    my $client  = $grant->{client};
    my $command = "$Provisioner::Vars::SCRIPT_DIR/nginxrelay_client release $client";
    return (
        command => $command,
        doing   => "release the public names of $client",
        done    => "Released the public names of $client",
        stays   => "it still sends the public names of $client to its old address.  Run $command there before another guest gets the address",
    );
}

sub template_files {
    my ($self) = @_;
    return (
        $self->SUPER::template_files(),
        'nginxrelay.stream.tt'    => 'nginxrelay.stream',
        'nginxrelay.http.conf.tt' => 'nginxrelay.http.conf',
        'nginxrelay.ufw.conf.tt'  => 'nginxrelay_ufw.conf',
    );
}

sub tests {
    return qw{nginxrelay.tt};
}

1;
