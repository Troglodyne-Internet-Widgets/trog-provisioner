package Provisioner::Recipe::matrix;

#ABSTRACT: Install and configure a Matrix Synapse homeserver.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Crypt::PRNG();
use MIME::Base64();

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
            smtp_domain: example.test

=head2 DESCRIPTION

Installs and configures a Matrix Synapse homeserver behind an nginx reverse
proxy, with the ketesa admin web interface.  This recipe requires the
C<nginxproxy> recipe.

Synapse answers at C<matrix.$domain>, and the admin interface at
C<admin.matrix.$domain>.  Add C<matrix> and C<admin.matrix> to the C<aliases>
section of F<ipmap.cfg> for the domain, so that the SSL certificate covers
them.

The package names are in the subclass for each distribution, for example
L<Provisioner::Recipe::Ubuntu::matrix>.

=head2 %required = $recipe->required_recipes(%opts)

C<nginxproxy>, with a vhost on port 80 that redirects to SSL, and a vhost on
port 443 that proxies to synapse on C<127.0.0.1:8008>.  nginx does not cache
the C<_matrix> and C<_synapse/client> paths.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    my $ipv6 = $opts{ipv6} // 1;
    return (
        nginxproxy => sub {
            (
                vhosts => {
                    80  => { ssl_redirect => 1, ipv6 => $ipv6 },
                    443 => {
                        ssl            => 1,
                        proxy_uri      => 'http://127.0.0.1:8008',
                        nocache_prefix => '^~ /(_matrix|_synapse/client)/',
                        ipv6           => $ipv6,
                    },
                },
            )
        },
    );
}

=head2 $bool = $recipe->is_multi_tenant()

False.  One synapse is one homeserver, and C<server_name> is the identity that
it federates under.  It cannot hold two of them.  The public base URL, the
database and the media store all follow from it.  So a second domain on the
guest does not join this homeserver.  It replaces it.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

The configuration that this recipe takes.  C<bin/recipes> lists it.

=cut

sub args {
    my ($self) = @_;
    return (
        type       => 'object',
        required   => [qw{server_name admin_password smtp_host smtp_user smtp_pass smtp_domain}],
        properties => {
            server_name => { type => 'string' },

            redis_password => { type => 'string', description => 'Password for the redis the homeserver caches in.  Unset configures the homeserver without one.' },

            # Listed on the index page of the guest.
            channels                   => { type => 'array',  items   => { type => 'string' }, default => [] },
            admin_user                 => { type => 'string', default => 'admin' },
            admin_password             => { type => 'string' },
            smtp_host                  => { type => 'string' },
            smtp_port                  => { type => 'integer', default => 465, minimum => 0 },
            smtp_user                  => { type => 'string' },
            smtp_pass                  => { type => 'string' },
            smtp_domain                => { type => 'string' },
            require_transport_security => { type => 'boolean', default => 1 },
            ipv6                       => { type => 'boolean', default => 1 },

            # Off by default, because the operator decides whether to report
            # usage.  See matrix.homeserver.yaml.tt for why synapse needs it.
            report_stats => { type => 'boolean', default => 0 },
            redis_host   => { type => 'string',  default => '127.0.0.1' },
            redis_port   => { type => 'integer', minimum => 1024, default => 6379 },
        },
    );
}

=head2 %files = $recipe->template_files()

A map from each template to the name of the file that it renders.

=cut

sub template_files {
    my ($self) = @_;

    return (
        'matrix.register_admin.sh.tt' => 'matrix_register_admin.sh',
        'matrix.homeserver.yaml.tt'   => 'homeserver.yaml',
        'matrix.log.yaml.tt'          => 'log.yaml',
        'matrix.admin.nginx.tt'       => 'matrix-admin.nginx.conf',
        'matrix.synapse.service.tt'   => 'matrix-synapse.service',
        'matrix.index.html.tt'        => 'matrix.index.html',
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
            generate => \&_signing_key,
            owner    => 'matrix-synapse:matrix-synapse',
            mode     => '0600',
        },
        "/etc/matrix-synapse/registration.shared.secret" => {
            ref      => "secret:matrix/$domain-registration-secret/password",
            generate => sub { Crypt::PRNG::random_bytes_hex(32) },
            owner    => 'matrix-synapse:matrix-synapse',
            mode     => '0600',
        },
    );
}

=head2 $key = _signing_key()

Returns a new signing key in the format that C<signedjson> writes.  That is the
algorithm, a short version tag that names this key among any others the server
had, and 32 seed bytes in base64 without padding.

The key is made here, not on the guest, because a guest that makes its own
makes a new one on every rebuild.

=cut

sub _signing_key {
    my $version = 'a_' . join( '', map { ( 'a' .. 'z', 'A' .. 'Z' )[ Crypt::PRNG::rand(52) ] } 1 .. 4 );
    my $seed    = MIME::Base64::encode_base64( Crypt::PRNG::random_bytes(32), '' );
    $seed =~ s/=+\z//;

    return "ed25519 $version $seed";
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
