package Provisioner::Recipe::nginxproxy;

#ABSTRACT: Set up caching nginx reverse proxy rules for the application.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nginxproxy

=head2 SYNOPSIS

Flat (new) interface  proxy_uri and static_dir at top level:

    somedomain:
        nginxproxy:
            proxy_uri:  run/app.sock
            static_dir: www/static

This automatically generates vhosts: port 80 redirects to HTTPS, port 443
proxies to the given socket with statics served from static_dir.

Nested (vhosts) interface  full control over per-port configuration:

    somedomain:
        nginxproxy:
            vhosts:
                443:
                    proxy_uri: path/to/socket/in/install_dir, or an http://uri
                    static_dir: www/static
                    public_dir: www/public
                    nocache_prefix: /secure
                    auth_statics: /seekrit
                    auth_uri: /ihazcookie
                    ipv6: false
                    ssl: true
                80:
                    ssl_redirect: true

=head2 DESCRIPTION

Sets up reverse proxy rules for the primary application to be deployed.

The idea here is to support aggressive caching of the outputs of the proxied application.
This is implemented through a try_files directive:

    try_files $url $url.html $url/index.html @default

You can set the name of the 'uncached' route to your application (nocache_prefix),
which is useful if you have necessarily dynamic pages.
Your application will have to strip that part of the route and then route as normal.

Alternatively, you can use the nocache_prefix as a way to serve at multiple odd endpoints by providing an appropriate location directive nginx will understand.
Example from the matrix recipe:
    nocache_prefix => '~ (_matrix|_synapse)/client'

In that case we still serve statics as exact matches, but not .html/.htm versions.
This way all your routes (e.g. /foo) can be dynamic while static assets (e.g. styles/foo.css) will
still be served by nginx.

It is up to your application to cull/regenerate/never generate .html versions of your routes when appropriate.

If no static_dir is set, it will be www/ in the domain's install dir.

You can also guard a folder for statics behind auth via the auth_statics and auth_uri mechanism.
The auth_uri should return 200 in the event the user is sufficiently authenticated (see nginx's L<auth_request|https://nginx.org/en/docs/http/ngx_http_auth_request_module.html>)

You can do auto-redirects to HTTPS via the ssl_redirect flag for non-ssl ports.

Supports connection upgrades to websocket, and does not use proxy buffering so comet requests & other streams are possible as well.

The public_dir field is for providing the same functionality as the nginxdirindex recipe.

=head2 USE AS DEPENDENCY

In general it is best to use this as a dependency to other recipes.  See tpsgi & tcms recipes for examples.

=cut

sub required_recipes {
    return (
        nginx => sub { () },
    );
}

sub args {
    return (
        type       => 'object',
        properties => {
            # The account that owns this domain's files.  Every template using
            # it did so bare, and nothing declared it, so it rendered empty --
            # `chown -R :group`, which quietly changes only the group.
            user     => { type => 'string' },
            vhosts     => {
                type => 'object',
                description => "vhost vars by port number",
                additionalProperties => {
                    type       => 'object',
                    properties => {
                        proxy_uri      => { type => 'string' },
                        static_dir     => { type => 'string' },
                        auth_statics   => { type => 'string' },
                        auth_uri       => { type => 'string' },
                        public_dir     => { type => 'string' },
                        nocache_prefix => { type => 'string' },
                        # No default: a vhost is either the redirect or the
                        # thing redirected to, and defaulting both this and ssl
                        # to true made every vhost claim to be both.
                        ssl_redirect   => { type => 'boolean' },
                        # No default here either, for the same reason: this one
                        # was left defaulting to true, so a port 80 vhost that
                        # asked for neither -- tcms and tpsgi both do -- came
                        # out as `listen 80 ssl` and spoke TLS on the plain HTTP
                        # port.  Every recipe that wants it says so.
                        ssl            => { type => 'boolean' },
                    },
                },
            },
            ipv6       => { type => 'boolean', default => 1 },
            # Declared here as well as in the nginx recipe, because each recipe
            # renders with its own configuration and nothing else: the split in
            # 5756b44 moved this to nginx and left the templates here using it,
            # so it has rendered as `backlog=` -- which nginx refuses -- ever
            # since.  It has to match nginx's, since somaxconn is set from that
            # and must be at least this.
            backlog    => { type => 'integer', default => 32768, minimum => 0 },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Nothing that pulls this recipe in supplies a user, and the admin owns
    # everything else on the guest.  Same as perl, nvm and mariadb.
    $opts{user} //= $opts{admin_user};

    # The flat interface: proxy_uri and static_dir at the top level, which the
    # SYNOPSIS says generates 80 redirecting to HTTPS and 443 proxying.  Nothing
    # was generating them, and the whole template is a loop over vhosts -- so a
    # domain configured this way rendered an empty vhost file and served
    # nothing.  Both domains using it in production are configured this way.
    if ( !$opts{vhosts} && ( $opts{proxy_uri} || $opts{static_dir} ) ) {
        my $ipv6 = $opts{ipv6} // 1;
        $opts{vhosts} = {
            80  => { ssl_redirect => 1, ipv6 => $ipv6 },
            443 => {
                ssl  => 1,
                ipv6 => $ipv6,
                ( $opts{proxy_uri}  ? ( proxy_uri  => $opts{proxy_uri} )  : () ),
                ( $opts{static_dir} ? ( static_dir => $opts{static_dir} ) : () ),
            },
        };
    }

    if ( $opts{vhosts} && ref $opts{vhosts} eq 'HASH' ) {
        # Nested vhosts interface: transform proxy_uri paths where needed.
        foreach my $key ( keys %{ $opts{vhosts} } ) {
            next unless $key =~ m/\d+/;
            my $vopts = $opts{vhosts}{$key};
            next if $vopts->{ssl_redirect};
            my $uri = $vopts->{proxy_uri};
            die "Must set proxy_uri in [nginxproxy] section" if !$uri;
            # let's make sure the proxy_uri accepts either a file or an actual uri
            # nginx wants http://unix:<path>:<uri> -- the socket path is
            # terminated by a colon and what follows it is the URI.  This built
            # `http://unix://opt/domains/<dom>/run/app.sock`: install_dir already
            # begins with a slash, so the path came out doubled, and with no
            # closing colon nginx refuses the whole file with "no closing \":\"
            # in unix domain socket".  Every guest proxying to a socket failed
            # to start nginx.
            $vopts->{proxy_uri} = "http://unix:$opts{install_dir}/$opts{domain}/$uri:/"
                if $uri && $uri !~ m/^http/;
        }
    }

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'nginx.domain.conf.tt'  => 'nginx.domain.conf',
    );
}

sub tests {
    return qw{nginxproxy.tt};
}

1;
