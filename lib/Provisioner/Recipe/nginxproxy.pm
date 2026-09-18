package Provisioner::Recipe::nginxproxy;

#ABSTRACT: Set up caching nginx reverse proxy rules for the application.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nginxproxy

=head2 SYNOPSIS

The flat interface puts proxy_uri and static_dir at the top level:

    somedomain:
        nginxproxy:
            proxy_uri:  run/app.sock
            static_dir: www/static

This makes two vhosts.  Port 80 redirects to HTTPS.  Port 443 proxies to the
socket and serves static files from static_dir.

The nested interface gives you full control of each port:

    somedomain:
        nginxproxy:
            ipv6: false
            vhosts:
                443:
                    proxy_uri: path/to/socket/in/install_dir, or an http://uri
                    static_dir: www/static
                    public_dir: www/public
                    nocache_prefix: /secure
                    auth_statics: /seekrit
                    auth_uri: /ihazcookie
                    ssl: true
                80:
                    ssl_redirect: true

=head2 DESCRIPTION

Sets up reverse proxy rules for the main application of the domain.

The vhost caches the output of the proxied application aggressively.  A
try_files directive does this:

    try_files $uri $uri.html $uri/index.html @default

nginx serves a file that exists and sends everything else to the application.

nocache_prefix names a route that always goes to your application.  Use it for
pages that must be dynamic.  Your application must strip that part of the route
and then route as usual.

nocache_prefix can also be any location that nginx accepts, to send several
endpoints to the application.  The matrix recipe uses this:

    nocache_prefix => '^~ /(_matrix|_synapse/client)/'

Under that location, nginx still serves a static file that matches exactly, but
not its .html version.  So every route (for example /foo) can be dynamic, while
nginx still serves static assets such as styles/foo.css.

Your application must remove, regenerate or never write .html versions of its
routes, as each case requires.

A vhost serves files only if a recipe tells it where they are.  With no
static_dir, the vhost has no C<root> and no C<try_files>, and it proxies
everything.  A reverse proxy in front of gogs or synapse wants this.  A recipe
that serves files sets static_dir, as tpsgi does.

auth_statics and auth_uri put a folder of static files behind authentication.
Both need static_dir as well.  auth_uri must return 200 when the user is
authenticated.  See the nginx
L<auth_request|https://nginx.org/en/docs/http/ngx_http_auth_request_module.html>
module.

On a port without SSL, ssl_redirect redirects every request to HTTPS.

The vhost passes websocket connection upgrades through.  It turns proxy
buffering off, so long polling requests and other streams also work.

public_dir gives the same directory index as the nginxdirindex recipe.

ipv6 is a top-level setting, and it applies to every vhost.

=head2 USE AS DEPENDENCY

Usually another recipe requires this one.  See the tpsgi and tcms recipes for
examples.

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
            vhosts => {
                type                 => 'object',
                description          => "vhost vars by port number",
                additionalProperties => {
                    type       => 'object',
                    properties => {
                        proxy_uri      => { type => 'string' },
                        static_dir     => { type => 'string' },
                        auth_statics   => { type => 'string' },
                        auth_uri       => { type => 'string' },
                        public_dir     => { type => 'string' },
                        nocache_prefix => { type => 'string' },

                        # No default for this or ssl: a vhost is either the
                        # redirect or the target of it, so each recipe says which.
                        ssl_redirect => { type => 'boolean' },

                        ssl => { type => 'boolean' },
                    },
                },
            },

            # The flat interface, which enrich turns into the two vhosts in the
            # SYNOPSIS.  The schema names these so that bin/recipes prints them.
            proxy_uri  => { type => 'string', description => 'Where to send what this domain does not serve from disk: a socket path under the install directory, or an http:// URI.  Generates a port 80 vhost redirecting to HTTPS and a 443 vhost proxying here, so it is the whole configuration for the usual arrangement.  Use vhosts instead to say anything more.' },
            static_dir => { type => 'string', description => 'Files served straight from disk, as a path under the install directory.  Goes into the generated 443 vhost alongside proxy_uri; see that field for when to use vhosts instead.' },

            ipv6 => { type => 'boolean', default => 1 },

            # Also declared in the nginx recipe, because each recipe renders
            # with only its own configuration.  Keep the two equal: somaxconn
            # comes from the nginx value and must be at least this one.
            backlog => { type => 'integer', default => 32768, minimum => 0 },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Returns %opts ready for the templates.

=over 4

=item *

If vhosts is not set and proxy_uri or static_dir is, it makes vhosts from them
as the SYNOPSIS describes.

=item *

In each vhost that is not a redirect, a proxy_uri that does not start with
C<http> is a socket path under the install directory of the domain.  enrich
replaces it with C<http://> and the name of an upstream, and puts each upstream
in the C<upstreams> hash, name to socket path.

=item *

C<serves_static> is 1 if any vhost has a static_dir, and 0 if none has.

=item *

C<traverse_dirs> lists every directory between the domain root and each
static_dir, without static_dir itself.

=back

Dies if a vhost that is not a redirect has no proxy_uri.

nginx refuses a socket inline in proxy_pass in every form.  With the URI part
that the socket form needs, inside a named location, it says:

    "proxy_pass" cannot have URI part in location given by regular
    expression, or inside named location, or inside "if" statement

Without the colon that ends the socket path, it says:

    no closing ":" in unix domain socket

An upstream has no URI part, so neither error applies.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    # The template loops over vhosts, so make them for the flat interface.
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

        # A socket goes through an upstream because nginx refuses it inline.
        # The POD for enrich has the two errors.
        my %upstreams;
        foreach my $key ( keys %{ $opts{vhosts} } ) {
            next unless $key =~ m/\d+/;
            my $vopts = $opts{vhosts}{$key};
            next if $vopts->{ssl_redirect};

            my $uri = $vopts->{proxy_uri};
            die "Must set proxy_uri in [nginxproxy] section" if !$uri;
            next                                             if $uri =~ m/^http/;

            # Named for the socket, so that vhosts which share one socket share
            # one upstream.
            my $socket = "$opts{install_dir}/$opts{domain}/$uri";
            ( my $name = "sock_$socket" ) =~ s/\W/_/g;

            $upstreams{$name} = $socket;
            $vopts->{proxy_uri} = "http://$name";
        }
        $opts{upstreams} = \%upstreams;

        # The directories that www-data must traverse to reach each static_dir.
        # templates/ubuntu/nginxproxy.tt says why they need o+x.
        my $serves_static;
        my %traverse;
        foreach my $vopts ( values %{ $opts{vhosts} } ) {
            next if $vopts->{ssl_redirect};
            next unless $vopts->{static_dir};
            $serves_static = 1;
            my @parts = split m{/}, $vopts->{static_dir};
            pop @parts;
            my $path = '';
            foreach my $part (@parts) {
                $path = $path ? "$path/$part" : $part;
                $traverse{$path} = 1;
            }
        }
        $opts{serves_static} = $serves_static ? 1 : 0;
        $opts{traverse_dirs} = [ sort keys %traverse ];
    }

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'nginx.domain.conf.tt' => 'nginx.domain.conf',
    );
}

sub tests {
    return qw{nginxproxy.tt};
}

1;
