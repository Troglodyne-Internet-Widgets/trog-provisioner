package Provisioner::Recipe::matrix;

#ABSTRACT: Install and configure a Matrix Synapse homeserver.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Crypt::PRNG();
use List::Util();
use MIME::Base64();

use Provisioner::Cookbook();

=head1 Provisioner::Recipe::matrix

=head2 SYNOPSIS

    somedomain:
        matrix:
            server_name: matrix.example.test
            admin_user: admin
            admin_password: somepassword
            smtp_host: smtp.example.test
            smtp_port: 465
            smtp_user: notifications@example.test
            smtp_pass: smtp_password
            smtp_from: notifications@example.test

=head2 DESCRIPTION

Installs and configures a Matrix Synapse homeserver behind nginx, with the
ketesa admin web interface and Element Web, a client in the browser.

C<server_name> is the identity of the homeserver.  Every account is
C<@user:$server_name>, every room alias ends in C<:$server_name>, and other
servers know this one by that name and its signing key.  It cannot change
after the first start, so the recipe has no default for it.  To take over an
existing homeserver, give the name that it already has.  It cannot be the
domain, C<www.$domain> or an alias of the domain, because the vhost of the
domain answers for those, and the homeserver has a vhost of its own.

=head2 The names of the guest

=over 4

=item * The domain and its aliases serve a page with a link to Element.
C<nginxproxy> serves it from F<www/index.html> in the domain directory, and
sends the rest to synapse.

=item * C<matrix.$domain> is the vhost of the homeserver, in
F<matrix.nginx.conf>.  It serves synapse on 443 and on 8448, the port of
federation.  It answers for C<server_name> too, and serves the two well-known
documents there.  C<server_name> is the name that clients and other servers
use: C</.well-known/matrix/server> says C<$server_name:8448>, and
C</.well-known/matrix/client> says C<https://$server_name:8448>, which is the
C<public_baseurl> of synapse.

=item * C<admin.matrix.$domain> is the vhost of the admin interface, and
C<element.matrix.$domain> that of Element.  Users reach them as
C<admin.$server_name> and C<element.$server_name>, which each vhost also
answers for.  Element starts at the homeserver, C<https://$server_name:8448>.
Both are downloaded from their GitHub releases on every provision.

=back

The certificate of the domain covers C<matrix.$domain>,
C<admin.matrix.$domain> and C<element.matrix.$domain>, because they are the
C<subdomains> of this recipe.
C<server_name> is on it when it is in the zone of the domain, or in a zone that
an account of L<Provisioner::Recipe::registrar> lists.

=head2 Behind a relay

When the C<nginx> of the domain names a C<relay>, this recipe hands C<nginx>
these C<public_names>: the domain and each of its aliases, for the page,
C<server_name>, for the vhost of the homeserver, and C<admin.$server_name> and
C<element.$server_name>, for their vhosts.  The admin interface is public as
the admin API that it calls is, through C<server_name> on 8448.  The relay
passes them through on 443.  C<server_name> also has the port 8448, mapped to
8449, so the relay
passes it alone through on 8448 to 8449 of the guest.  The vhost of the
homeserver listens there, with the PROXY protocol.  See
L<Provisioner::Recipe::nginx/Ports of its own>.

If C<server_name> is in no zone that the guest can publish and certify,
C<nginx> publishes and certifies C<public.matrix.$domain> in its place, and
C<public.admin.matrix.$domain> and C<public.element.matrix.$domain> for the
names under it.  Then the operator points C<server_name> and
those names at the relay by hand, and the certificate of the guest does not
cover them until they do.  See
L<Provisioner::Recipe::nginx/Names that reach the guest through a proxy>.

=head2 Taking over a homeserver

A homeserver is three things: its signing key, its database and its media
store.  To move one that this recipe did not build onto a guest, put all three
in place before the first build.  Give C<server_name> the name that the old
server has.

=over 4

=item 1. Stop synapse on the old server, so that the database and the media
store do not change while you copy them.

=item 2. Put the signing key of the old server into the secret store.  It is
the file that C<signing_key_path> in the old F<homeserver.yaml> names, one line
of the form C<ed25519 $version $seed>:

    bin/add_secret --group matrix --title $domain-signing-key --stdin < homeserver.signing.key

Add C<--overwrite> if an earlier build already generated a key there.

=item 3. Copy the database into the data directory of the domain, which is
C<$data_source/$domain> on the machine that runs this tool.  See C<data_dir> in
L<Provisioner::Cookbook>.  It goes to F<matrix/homeserver.db> there.  On the old
server, make the copy with the backup command of sqlite3, which writes one
consistent file, and move that file there:

    sqlite3 /path/to/old/homeserver.db ".backup '/path/to/copy/homeserver.db'"

=item 4. Copy the contents of the old C<media_store_path> into F<matrix/media/>
in the same directory.

=item 5. If the old server had keys before its current one, give their public
halves in C<old_signing_keys>, as the C<old_verify_keys> of the old server's
C</_matrix/key/v2/server> lists them.  Synapse keeps publishing them, so other
servers can still check the events that they signed.

=back

The data target brings F<matrix/> onto the guest, and C<restores> moves it to
C<$install_dir/matrix.$domain>, where synapse reads it.  That is the path of a
salvage from a guest that this recipe built.

The recipe takes sqlite3 only.  Synapse's C<synapse_port_db> moves a database
from sqlite3 to PostgreSQL, and synapse ships no tool for the other direction.
So a homeserver on PostgreSQL cannot be taken over.

Before synapse is enabled, F<matrix_check_signing_key> reads the newest events
that accounts of C<server_name> sent.  If there are some, and none of them
carries a signature under the ID of the key in the store or of a key in
C<old_signing_keys>, the build stops, and synapse does not start.  That
combination is a restored database with a new key, usually because step 2 was
missed.  Other servers would see a known name with a key they do not know.  Put
the right key in the store, and build again.

The package names are in the subclass for each distribution, for example
L<Provisioner::Recipe::Ubuntu::matrix>.

=cut

# The port of federation, and of the client API at public_baseurl.
our $FEDERATION_PORT = 8448;

# Whether the nginx of $domain sends its public names through a relay.
my sub relayed ($domain) {
    return defined( ( Provisioner::Cookbook->domain_config($domain)->{nginx} // {} )->{relay} );
}

# The port of the guest where the relay passes federation through, with the
# PROXY protocol.
our $PASSTHROUGH_PORT = 8449;

# The names under server_name of the admin interface and of Element.
my sub client_names ($server_name) {
    return ( "admin.$server_name", "element.$server_name" );
}

=head2 %required = $recipe->required_recipes(%opts)

C<nginx>, with C<matrix.$domain>, C<admin.matrix.$domain> and
C<element.matrix.$domain> in C<sites>, and the C<public_names> of
L</Behind a relay> when the domain has a relay.

C<nginxproxy>, with a vhost on port 80 that redirects to SSL, and a vhost on
port 443 that serves the page from F<www> and proxies the rest to synapse on
C<127.0.0.1:8008>.  nginx does not cache the C<_matrix> and C<_synapse/client>
paths.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    my $ipv6   = $opts{ipv6} // 1;
    my $domain = $opts{domain};
    return (
        nginx => sub {
            my @sites = map { "$_.$domain" } $self->subdomains();
            return ( sites => [@sites] ) unless relayed($domain);
            my %ours    = map  { $_ => 1 } @sites, defined $opts{server_name} ? ( $opts{server_name}, client_names( $opts{server_name} ) ) : ();
            my @aliases = grep { !$ours{$_} } @{ Provisioner::Cookbook->alias_map()->{$domain} // [] };
            return (
                sites        => [@sites],
                public_names => {
                    ( map { $_ => { vhost => $domain } } $domain, @aliases ),
                    (
                        defined $opts{server_name}
                        ? (
                            $opts{server_name}           => { vhost => "matrix.$domain", ports => { $FEDERATION_PORT => $PASSTHROUGH_PORT } },
                            "admin.$opts{server_name}"   => { vhost => "admin.matrix.$domain" },
                            "element.$opts{server_name}" => { vhost => "element.matrix.$domain" },
                          )
                        : ()
                    ),
                },
            );
        },
        nginxproxy => sub {
            (
                vhosts => {
                    80  => { ssl_redirect => 1, ipv6 => $ipv6 },
                    443 => {
                        ssl            => 1,
                        proxy_uri      => 'http://127.0.0.1:8008',
                        static_dir     => 'www',
                        nocache_prefix => '^~ /(_matrix|_synapse/client)/',
                        ipv6           => $ipv6,
                    },
                },
            )
        },
    );
}

=head2 @claims = $recipe->listens()

synapse on 8008, on 127.0.0.1 and on ::1, for clients and for federation both.

=cut

sub listens {
    return qw{127.0.0.1:8008 [::1]:8008};
}

=head2 %limits = $recipe->rate_limits(%opts)

8448, where the vhost of the homeserver serves federation, at the limit that
C<nginx> gives 443.  Behind a relay, also the port where the relay passes 8448
through.  See L</Behind a relay>.  The ufw profile C<matrix-homeserver> opens
the same ports.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;
    my %limits = Provisioner::Cookbook->load('nginx')->rate_limits();
    return ( $FEDERATION_PORT => $limits{443}, relayed( $opts{domain} ) ? ( $PASSTHROUGH_PORT => $limits{443} ) : () );
}

=head2 $bool = $recipe->is_multi_tenant()

False.  One synapse is one homeserver, and C<server_name> is the identity that
it federates under.  It cannot hold two of them.  The public base URL, the
database and the media store all follow from it.  So a second domain on the
guest does not join this homeserver.  It replaces it.

=cut

sub is_multi_tenant { return 0 }

=head2 @names = $recipe->subdomains()

C<matrix>, which synapse is reached at, and C<admin.matrix> and
C<element.matrix>, the vhosts of the admin interface and of Element.  Users
reach those two at the names under C<server_name>.  See L</The names of the
guest>.

=cut

sub subdomains {
    return qw{matrix admin.matrix element.matrix};
}

=head2 %args = $recipe->args()

The configuration that this recipe takes.  C<bin/recipes> lists it.

=cut

sub args {
    my ($self) = @_;
    return (
        type       => 'object',
        required   => [qw{server_name admin_password smtp_host smtp_user smtp_pass smtp_from}],
        properties => {
            server_name => { type => 'string', description => 'The permanent name of the homeserver, the part after the colon of every account and room alias.  See DESCRIPTION.' },

            redis_password => { type => 'string', 'x-secret' => 1, description => 'Password for the redis the homeserver caches in.  Unset configures the homeserver without one.' },

            old_signing_keys => {
                type                 => 'object',
                default              => {},
                description          => 'The keys that the homeserver signed with before its current one, by key ID.  See Taking over a homeserver.',
                propertyNames        => { pattern => '\Aed25519:[A-Za-z0-9_]+\z' },
                additionalProperties => {
                    type       => 'object',
                    required   => [qw{public expired_ts}],
                    properties => {
                        public     => { type => 'string',  pattern => '\A[A-Za-z0-9+/]{43}\z', description => 'The public half of the key, in base64 without padding, as /_matrix/key/v2/server published it.' },
                        expired_ts => { type => 'integer', minimum => 0,                       description => 'When the key stopped signing, in milliseconds since the epoch.' },
                    },
                },
            },

            channels => {
                type        => 'array',
                default     => ['general'],
                description => 'The rooms that each new account joins.  synapse makes a room that does not exist yet.',
                items       => {
                    type        => 'string',
                    pattern     => '^[^#:]+$',
                    description => 'The local part of a room alias, such as general.  The recipe adds the # and the server name.',
                },
            },
            admin_user                 => { type => 'string', default    => 'admin' },
            admin_password             => { type => 'string', 'x-secret' => 1 },
            smtp_host                  => { type => 'string' },
            smtp_port                  => { type => 'integer', default     => 465, minimum => 0, description => 'The port of smtp_host.  The ufw profile matrix-smtp opens it outbound.' },
            smtp_user                  => { type => 'string',  description => 'The login to smtp_host, which is not always an address.' },
            smtp_pass                  => { type => 'string',  'x-secret'  => 1 },
            smtp_from                  => { type => 'string',  format      => 'email', description => 'The address that notices from the homeserver come from.' },
            require_transport_security => { type => 'boolean', default     => 1 },
            ipv6                       => { type => 'boolean', default     => 1 },

            # Off by default, because the operator decides whether to report
            # usage.  See matrix.homeserver.yaml.tt for why synapse needs it.
            report_stats => { type => 'boolean', default => 0 },
            redis_host   => { type => 'string',  default => '127.0.0.1' },
            redis_port   => { type => 'integer', minimum => 1024, default => 6379 },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<federation_port>, 8448, and C<relayed>, true when the domain has a
relay.  Behind a relay, it also adds C<passthrough_port>, where the relay
passes 8448 through.  See L</Behind a relay>.

Adds C<homeserver_names>, the C<server_name> of the vhost of the homeserver:
C<matrix.$domain>, and C<server_name> without a relay.  Behind one, the file
of the proxy that the vhost includes names C<server_name>, so the vhost does
not name it a second time.  C<admin_names> and C<element_names> are the same
for the vhosts of the admin interface and of Element, with
C<admin.$server_name> and C<element.$server_name>.

Dies when C<server_name> is the domain, C<www.$domain> or an alias of the
domain, because the vhost of the domain answers for those.

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    my $domain = $opts{domain};

    my %of_domain = map { $_ => 1 } $domain, "www.$domain", @{ Provisioner::Cookbook->alias_map()->{$domain} // [] };
    die "matrix: server_name is $opts{server_name}, which the vhost of $domain answers for.  The homeserver needs a name of its own, which can be the name that it already has.\n"
      if $of_domain{ $opts{server_name} };

    $opts{federation_port}  = $FEDERATION_PORT;
    $opts{relayed}          = relayed($domain) ? 1 : 0;
    $opts{passthrough_port} = $PASSTHROUGH_PORT if $opts{relayed};
    $opts{homeserver_names} = [ List::Util::uniq( "matrix.$domain", $opts{relayed} ? () : $opts{server_name} ) ];
    my ( $admin, $element ) = client_names( $opts{server_name} );
    $opts{admin_names}   = [ "admin.matrix.$domain",   $opts{relayed} ? () : $admin ];
    $opts{element_names} = [ "element.matrix.$domain", $opts{relayed} ? () : $element ];
    return %opts;
}

=head2 %files = $recipe->template_files()

A map from each template to the name of the file that it renders.

=cut

sub template_files {
    my ($self) = @_;

    return (
        'matrix.register_admin.sh.tt'   => 'matrix_register_admin.sh',
        'matrix.homeserver.yaml.tt'     => 'homeserver.yaml',
        'matrix.log.yaml.tt'            => 'log.yaml',
        'matrix.admin.nginx.tt'         => 'matrix-admin.nginx.conf',
        'matrix.element.nginx.tt'       => 'matrix-element.nginx.conf',
        'matrix.element.config.json.tt' => 'element.config.json',
        'matrix.nginx.tt'               => 'matrix.nginx.conf',
        'matrix.ufw.conf.tt'            => 'matrix_ufw.conf',
        'matrix.synapse.service.tt'     => 'matrix-synapse.service',
        'matrix.index.html.tt'          => 'matrix.index.html',
    );
}

=head2 @dirs = $recipe->datadirs()

C<matrix>, the directory in the data directory of the domain where the salvaged
homeserver lands.  C<restores> puts it back from there.

=cut

sub datadirs {
    return qw{matrix};
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain)

The signing key of the homeserver and the registration shared secret, each
generated once and kept in the secret store.  The signing key is the identity
that the rest of the federation knows this server by.

The signing key is in the format that C<signedjson> writes.  That is the
algorithm, a short version tag that names this key among any others the server
had, and 32 seed bytes in base64 without padding.  It is made here, not on the
guest, because a guest that makes its own makes a new one on every rebuild.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    # Under /etc/matrix-synapse, not the domain directory, for two reasons.  A
    # secret placed where the salvage goes back stops restore_state, which does
    # nothing when its destination already holds a file.  And the data recipe
    # carries the domain directory into every backup.
    return (
        "/etc/matrix-synapse/homeserver.signing.key" => {
            ref      => "secret:matrix/$domain-signing-key/password",
            generate => sub {
                my $version = 'a_' . join( '', map { ( 'a' .. 'z', 'A' .. 'Z' )[ Crypt::PRNG::rand(52) ] } 1 .. 4 );
                my $seed    = MIME::Base64::encode_base64( Crypt::PRNG::random_bytes(32), '' );
                $seed =~ s/=+\z//;

                return "ed25519 $version $seed";
            },
            owner => 'matrix-synapse:matrix-synapse',
            mode  => '0600',
        },
        "/etc/matrix-synapse/registration.shared.secret" => {
            ref      => "secret:matrix/$domain-registration-secret/password",
            generate => sub { Crypt::PRNG::random_bytes_hex(32) },
            owner    => 'matrix-synapse:matrix-synapse',
            mode     => '0600',
        },
    );
}

=head2 @patterns = $recipe->remote_skip()

C<homeserver.signing.key>.  The key comes from the secret store, so it must not
come back off a guest into the domain directory and its backups.

The key lives under F</etc/matrix-synapse>, which is not salvaged.  A guest built
by an older version of this recipe can still have a copy in its domain
directory, and this keeps a rebuild from fetching it.

=cut

sub remote_skip {
    return ('homeserver.signing.key');
}

=head2 %restores = $recipe->restores(%opts)

Puts the salvaged homeserver back at C<$install_dir/matrix.$domain>.  That is
the database and the media store.

=cut

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # No owner: the fragment chowns the whole tree after it installs synapse.
    return ( "$install_dir/matrix.$domain" => { from => "$install_dir/$domain/matrix" } );
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

The homeserver directory, which is everything this server is.  C<homeserver.db>
holds every room, message and account, and the media store is next to it.  A
guest rebuilt without them starts empty.  C<restores> puts them back before
synapse starts.

The admin interface is not salvaged.  The fragment downloads it from its GitHub
release on every provision.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;

    return (
        "$install_dir/matrix.$domain/" => 'matrix/',
    );
}

=head2 @tests = $recipe->tests()

F<matrix.tt>, the test that runs on the guest.

=cut

sub tests {
    return qw{matrix.tt};
}

=head2 %jails = $recipe->jails()

A jail that bans a host whose logins fail too often.  synapse answers a failed
login with a 403, and its access log names the address that nginx forwarded:

    2026-09-19 16:18:06,793 - synapse.access.http.8008 - 643 - INFO - POST-3 - 192.168.122.50 - 8008 - {None} Processed request: 0.003sec/0.001sec ru=(0.001sec, 0.000sec) db=(0.000sec/0.000sec/1) 64B 403 "POST /_matrix/client/v3/login HTTP/1.1" "curl/8.5.0" [0 dbevts]

After three of those in a row, synapse answers with a 429 of its own, and the
jail counts that too.  A host that stopped at the 429 would never reach the
ban.  fail2ban ships no filter for synapse.

=cut

sub jails {
    return (
        'matrix-login' => {
            filter    => '',
            backend   => 'auto',
            port      => 'http,https',
            logpath   => '/var/log/matrix-synapse/homeserver.log',
            failregex => '^ - synapse\.access\.http\.\d+ - \d+ - INFO - \S+ - <HOST> - \d+ - \{\S*\} Processed request: .* (?:403|429) "POST /_matrix/client/(?:r0|v3)/login HTTP',
        },
    );
}

=head2 @hosts = $recipe->fetch_hosts()

C<packages.matrix.org>, which serves the synapse package.  Also GitHub, which
serves the ketesa admin interface as a release.  See C<github_release_hosts> in
L<Provisioner::Recipe>.

=cut

sub fetch_hosts {
    my ($class) = @_;
    return ( 'packages.matrix.org', $class->github_release_hosts );
}

=head2 @classes = $recipe->cache_classes()

The classes for the apt repository at C<packages.matrix.org>, and the classes
for GitHub.  L<Provisioner::Recipe> keeps both, so that each recipe does not
carry its own copy.

=cut

sub cache_classes {
    my ($class) = @_;
    return ( $class->apt_repo_classes('packages.matrix.org'), $class->github_release_classes );
}

1;
