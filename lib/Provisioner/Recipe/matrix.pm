package Provisioner::Recipe::matrix;

#ABSTRACT: Install and configure a Matrix Synapse homeserver.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use Crypt::PRNG();
use MIME::Base64();

=head1 Provisioner::Recipe::matrix

=head2 SYNOPSIS

    somedomain:
        matrix:
            admin_user: admin
            admin_password: somepassword
            smtp_host: smtp.example.test
            smtp_port: 465
            smtp_user: notifications@example.test
            smtp_pass: smtp_password
            smtp_domain: example.test

=head2 DESCRIPTION

Installs and configures Matrix Synapse homeserver with nginx reverse proxy,
and includes Synapse Admin web interface. Requires nginxproxy recipe.

NOTE: For SSL certificates to work properly with matrix subdomains, ensure
'matrix' and 'admin.matrix' are included in the aliases section of ipmap.cfg
for your domain.

=head3 deps

Returns system package dependencies for Matrix Synapse.

=over 1

=item INPUTS: none

=item OUTPUTS: list of Debian package names

=back

=head3 enrich

Sets defaults and computes derived configuration options.

=over 1

=item INPUTS: %opts hash with matrix configuration

=item OUTPUTS: processed %opts hash

=back

=head3 template_files

Returns template file mappings.

=over 1

=item INPUTS: none

=item OUTPUTS: hash of template source => destination mappings

=back

=head3 datadirs

Where the salvaged homeserver lands in the domain's data directory, so that the
fragment has a fixed place to look for it whether or not there was a guest to
take it off.

There was a C<matrix-admin> beside it that nothing has ever written to: the
admin interface came down as C<admin.matrix>, and no longer comes down at all.

=over 1

=item INPUTS: none

=item OUTPUTS: list of directory names

=back

=head3 remote_files

The homeserver directory, which is everything this server is.  C<homeserver.db>
holds every room, message and account; the media store sits beside it; and
C<homeserver.signing.key> is the identity the rest of the federation knows it
by.  A guest rebuilt without them is a stranger wearing the same name, so the
fragment puts them back with C<restore_state> before synapse is started.

The admin interface used to be salvaged too, and is not any more.  The fragment
downloads it from its GitHub release on every provision, so a copy of it went
down to the hypervisor and back up again preserving nothing, and sat in the
backups being a web application somebody else maintains.

=over 1

=item INPUTS: $install_dir, $domain

=item OUTPUTS: hash of remote path => local backup path

=back

=cut

# XXX this probably does not work in isolation!
sub required_recipes {
    my ( $self, %opts ) = @_;
    my $ipv6 = $opts{ipv6} // 1;
    return (
        nginxproxy => sub {
            (
                vhosts => {
                    80  => { ssl_redirect => 1, ipv6 => 1 },
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

sub args {
    my ($self) = @_;
    return (
        type       => 'object',
        required   => [qw{server_name admin_password smtp_host smtp_user smtp_pass smtp_domain}],
        properties => {

            # The account that owns this domain's files.  Every template using
            # it did so bare, and nothing declared it, so it rendered empty --
            # `chown -R :group`, which quietly changes only the group.
            user        => { type => 'string' },
            server_name => { type => 'string' },

            # Listed on the guest's index page.  The template used it before
            # anything declared it, and its loop said chan while its body said
            # channel, so every suggestion came out as #@domain.
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

            # Synapse will not start until this is answered either way.  Off
            # unless the domain says otherwise: opting a homeserver into
            # reporting its usage is the operator's call, not this recipe's.
            report_stats => { type => 'boolean', default => 0 },
            redis_host   => { type => 'string',  default => '127.0.0.1' },
            redis_port   => { type => 'integer', minimum => 1024, default => 6379 },
        },
    );
}

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

sub datadirs {
    return qw{matrix};
}

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    # Under synapse's own configuration directory rather than the domain
    # directory, for two reasons.  bin/provision places these before the
    # makefile runs, and matrix.tt restores its salvage into the domain
    # directory -- which restore_state declines to do once anything is sitting
    # in it, so a secret placed there stopped the media store coming back.  And
    # the domain directory is what the data recipe carries off to the
    # hypervisor and into every backup taken of it, which is the one place a
    # secret held in the store should never end up.
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

# What signedjson writes: the algorithm, a short version tag naming this key
# among any others the server has had, and the 32 seed bytes in unpadded
# base64.  Made here rather than on the guest because a guest that makes its own
# makes a new one every time it is rebuilt.
sub _signing_key {
    my $version = 'a_' . join( '', map { ( 'a' .. 'z', 'A' .. 'Z' )[ Crypt::PRNG::rand(52) ] } 1 .. 4 );
    my $seed    = MIME::Base64::encode_base64( Crypt::PRNG::random_bytes(32), '' );
    $seed =~ s/=+\z//;

    return "ed25519 $version $seed";
}

# The signing key is in the secret store and is put on the guest from there, so
# it has no business coming back off one -- salvaged, it would sit in the domain
# directory and in every backup taken of it.
#
# Kept now that the key is placed under /etc/matrix-synapse and cannot be
# salvaged from there anyway: a guest built before that move still has one in
# its domain directory, and this is what stops a rebuild carrying it home.
sub remote_skip {
    return ('homeserver.signing.key');
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # The media store and the database.  No owner: the fragment chowns the whole
    # tree to matrix-synapse afterwards anyway.
    return ( "$install_dir/matrix.$domain" => { from => "$install_dir/$domain/matrix" } );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;

    # The homeserver only.  admin.matrix was salvaged beside it, and the
    # fragment re-downloads that release from GitHub every provision regardless,
    # so the round trip preserved nothing and only put somebody else's web
    # application in our backups.
    return (
        "$install_dir/matrix.$domain/" => 'matrix/',
    );
}

sub tests {
    return qw{matrix.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

GitHub, which serves the ketesa admin interface as a release: see
C<github_release_hosts> in L<Provisioner::Recipe>.

=cut

sub fetch_hosts {
    my ($class) = @_;
    return $class->github_release_hosts;
}

1;
