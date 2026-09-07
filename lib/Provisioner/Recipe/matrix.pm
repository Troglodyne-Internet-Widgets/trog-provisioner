package Provisioner::Recipe::matrix;

#ABSTRACT: Install and configure a Matrix Synapse homeserver.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::matrix

=head2 SYNOPSIS

    somedomain:
        matrix:
            admin_user: admin
            admin_password: somepassword
            smtp_host: smtp.example.com
            smtp_port: 465
            smtp_user: notifications@example.com
            smtp_pass: smtp_password
            smtp_domain: example.com

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

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{
          python3-cryptography
          python3-bcrypt
          python3-pil
          python3-twisted
          python3-yaml
          python3-jsonschema
          python3-netaddr
          python3-phonenumbers
          python3-prometheus-client
          python3-bleach
          python3-jinja2
          python3-sortedcontainers
          python3-treq
          python3-service-identity
          python3-signedjson
          python3-canonicaljson
          python3-attr
          python3-txacme
          python3-matrix-common
          python3-unpaddedbase64
          python3-pymacaroons
          python3-msgpack
        };
    }
    die "Unsupported packager";
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
            registration_shared_secret => { type => 'string',  default => $self->persisted_secret('registration_shared_secret.txt') },
            ipv6                       => { type => 'boolean', default => 1 },
            redis_host                 => { type => 'string',  default => '127.0.0.1' },
            redis_port                 => { type => 'integer', minimum => 1024, default => 6379 },
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

1;
