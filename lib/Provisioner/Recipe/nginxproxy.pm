package Provisioner::Recipe::nginxproxy;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nginxproxy

=head2 SYNOPSIS

Flat (new) interface — proxy_uri and static_dir at top level:

    somedomain:
        nginxproxy:
            proxy_uri:  run/app.sock
            static_dir: www/static

This automatically generates vhosts: port 80 redirects to HTTPS, port 443
proxies to the given socket with statics served from static_dir.

Nested (vhosts) interface — full control over per-port configuration:

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
            vhosts     => {
                type => 'object',
                description => "vhost vars by port number",
                additionalProperties => {
                    type       => 'object',
                    parameters => {
                        proxy_uri      => { type => 'string' },
                        static_dir     => { type => 'string' },
                        auth_statics   => { type => 'string' },
                        auth_uri       => { type => 'string' },
                        public_dir     => { type => 'string' },
                        nocache_prefix => { type => 'string' },
                        ssl_redirect   => { type => 'boolean' },
                        ssl            => { type => 'boolean' },
                    },
                },
            },
            ipv6       => { type => 'boolean' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    if ( $opts{vhosts} && ref $opts{vhosts} eq 'HASH' ) {
        # Nested vhosts interface: transform proxy_uri paths where needed.
        foreach my $key ( keys %{ $opts{vhosts} } ) {
            next unless $key =~ m/\d+/;
            my $vopts = $opts{vhosts}{$key};
            next if $vopts->{ssl_redirect};
            my $uri = $vopts->{proxy_uri};
            die "Must set proxy_uri in [nginxproxy] section" if !$uri;
            # let's make sure the proxy_uri accepts either a file or an actual uri
            $vopts->{proxy_uri} = "http://unix:/$opts{install_dir}/$opts{domain}/$uri"
                if $uri && $uri !~ m/^http/;
        }
    }
    $opts{ipv6} //= 1;
    $opts{ipv6} = !!$opts{ipv6};

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
