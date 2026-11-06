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

=head2 Media names

A guest can also register a media name, such as C<media.$domain>, from which
readers fetch its uploaded files.  This guest does not pass a media name
through.  It ends TLS for it, and caches what readers fetch, so a file crosses
the link to the guest once, not on each request.

The stream proxy sends a media name to a server of this guest on the socket
C<$MEDIA_SOCKET>, with the PROXY protocol.  That server:

=over 4

=item * presents the certificate of the SNI name from
F</etc/nginx/nginxrelay.d/media>.  The guest gets that certificate itself, by
DNS-01, and sends it here with a key that can run only C<nginxrelay_client
cert>.  So this guest holds the key of each media name, and of no name that
passes through.  Until the certificate arrives, a TLS connection for the name
fails its handshake.

=item * fetches what it does not hold from the HTTP port of the guest, with the
media name as the C<Host>.

=item * caches each file in slices of one megabyte, so a reader who seeks in a
video makes it fetch one slice.  The cache is in
F</var/cache/nginx/nginxrelay-media>, at most C<media_cache_size>, and it keeps a
file for C<media_cache_valid>, whatever the guest says.

=item * drops the C<Cookie> of the reader and the C<Set-Cookie> of the guest,
so every reader gets the same file.

=item * takes only C<GET> and C<HEAD>.

=item * answers 404 under F</assets/private/> without asking the guest.  The
guest gates that directory on the session of the reader, which this server
never sees.

=item * answers 421 when the C<Host> is not the SNI name.

=back

On 80, a media name redirects to HTTPS.  The bans close C<tls_port> and 80, so
they cover the media names too.  The response header C<X-Relay-Cache> says
whether the cache answered.

=head2 Page names

A guest can also register a page name, usually the domain itself, whose pages
this guest serves and caches as a reader sees them.  The guest then has a
second name, such as C<secure.$domain>, for the pages that need a login, which
passes through as every other name does.  So this guest sees the pages of
readers in the clear, and no password or session.

The stream proxy sends a page name to a server of this guest on the socket
C<$PAGE_SOCKET>.  That server takes its certificate as the media server does,
and also answers 421 when the C<Host> is not the SNI name.  It differs from the
media server in what it caches:

=over 4

=item * It caches a C<GET> or a C<HEAD> with no query string and no C<Cookie>,
for C<page_cache_valid>, whatever the guest says.  Then it asks the guest
whether the page changed, with C<If-Modified-Since> and C<If-None-Match>, so a
page that did not change costs a C<304>.  A response with C<Set-Cookie> is not
cached.

=item * A request with a query string or a C<Cookie> goes to the guest with
its cookie, and its answer is not cached.

=item * Any method other than C<GET> and C<HEAD> gets 404 without asking the
guest.  The forms that take a login are on the secure name, so a form body on
a page name is a mistake.

=item * While the guest does not answer, or answers with an error, readers get
the last page that the cache holds.

=back

The cache is in F</var/cache/nginx/nginxrelay-pages>, at most
C<page_cache_size>.  On 80, a page name redirects to HTTPS, as a media name
does.

This guest holds the key of each page name and media name, and no other key of
the guest.  The letsencrypt of the guest gives a page name a certificate of its
own, which names nothing else.  See L<Provisioner::Recipe::nginx/Cached names>.

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
            media_cache_size => {
                type        => 'string',
                pattern     => '^[1-9][0-9]*[kmg]$',
                default     => '1g',
                description => 'The most that the cache of the media names holds on disk, in the units of nginx, such as 512m or 4g.  See "Media names".',
            },
            media_cache_valid => {
                type        => 'string',
                pattern     => '^[1-9][0-9]*[mhd]$',
                default     => '7d',
                description => 'How long the cache of the media names keeps a file, in the units of nginx, such as 12h or 30d.  See "Media names".',
            },
            page_cache_size => {
                type        => 'string',
                pattern     => '^[1-9][0-9]*[kmg]$',
                default     => '256m',
                description => 'The most that the cache of the page names holds on disk, in the units of nginx.  See "Page names".',
            },
            page_cache_valid => {
                type        => 'string',
                pattern     => '^[1-9][0-9]*[smh]$',
                default     => '1m',
                description => 'How long the cache of the page names serves a page before it asks the guest whether the page changed, in the units of nginx, such as 30s or 5m.  A reader sees a page up to this late.  See "Page names".',
            },
        },
    );
}

# Also in scripts/nginxrelay_client, which runs on the relay without these
# libraries.  t/nginxrelay_client.t makes sure that the two are equal.
our $MEDIA_SOCKET = '/run/nginxrelay-media.sock';
our $PAGE_SOCKET  = '/run/nginxrelay-pages.sock';

=head2 %opts = $recipe->enrich(%opts)

Adds C<media_socket> and C<page_socket>, where the media server and the page
server listen, to what L<Provisioner::RelayRecipe/enrich> adds.

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    return ( $self->SUPER::enrich(%opts), media_socket => $MEDIA_SOCKET, page_socket => $PAGE_SOCKET );
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
C<< upstreams => { tls => $tls, http => $http } >>, C<< names => \@names >>, and
can have C<< media => \@media >> and C<< pages => \@pages >>.

The command is F<scripts/nginxrelay_client> C<register>, which root runs on the
relay.  C<$tls> and C<$http> are each an IPv4 address and a port, where the
relay sends TLS and plain HTTP for C<@names>.  See L</Registration>.

With C<@media>, the relay also registers each of them as a media name, which
it fetches from C<$http>, and with C<@pages>, each of them as a page name.  If
there is either, it issues the media key as well, at C<media_key_path> of the
client, with which the client sends the certificates of both.  See
L</Media names> and L</Page names>.

=cut

sub registration_files {
    my ( $self, $grant, %terms ) = @_;
    my $client = $grant->{client};
    my $script = "$Provisioner::Vars::SCRIPT_DIR/nginxrelay_client";
    my @media  = @{ $terms{media} // [] };
    my @pages  = @{ $terms{pages} // [] };

    my %files = (
        $self->key_path($client) => {
            issue => {
                guest   => $grant->{guest},
                command => join( q{ }, "$script register", $client, @{ $terms{upstreams} }{qw{tls http}}, @{ $terms{names} }, ( map { ( '--media', $_ ) } @media ), map { ( '--page', $_ ) } @pages ),
            },
            owner => 'root:root',
            mode  => '0600',
        },
    );
    return %files unless @media || @pages;

    my ($address) = split( m/:/, $terms{upstreams}{http} );
    return (
        %files,
        $self->media_key_path($client) => {
            issue => { guest => $grant->{guest}, command => "$script media-key $client $address" },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head2 $path = $recipe->media_key_path($domain)

Where the media key that this relay issues for C<$domain> is, on the guest of
C<$domain>, in base64.  The guest sends the certificates of its media names and
its page names with it.  See L</Media names>.

=cut

sub media_key_path {
    my ( $self, $domain ) = @_;
    return '/etc/ssl/' . $self->recipe_name . "/$domain.media.key.b64";
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
