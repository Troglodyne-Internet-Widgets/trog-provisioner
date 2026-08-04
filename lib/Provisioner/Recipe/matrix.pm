package Provisioner::Recipe::matrix;

use strict;
use warnings FATAL => 'all';

use parent qw{Provisioner::Recipe};
use List::Util;

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

=head3 validate

Validates and processes configuration options.

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

Returns directories to create for data storage.

=over 1

=item INPUTS: none

=item OUTPUTS: list of directory names

=back

=head3 remote_files

Returns remote file mappings for backup/restore.

=over 1

=item INPUTS: $install_dir, $domain

=item OUTPUTS: hash of remote path => local backup path

=back

=cut

# XXX this probably does not work in isolation!
sub required_recipes {
    return ( nginxproxy => sub { () } );
}

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{
          matrix-synapse-py3
          python3-cryptography
          python3-bcrypt
          python3-pillow
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
          python3-attrs
          python3-txacme
          python3-txredisapi
          python3-matrix-common
          python3-unpaddedbase64
          python3-pymacaroons
          python3-msgpack
        };
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    my $server_name = $opts{server_name};
    die "Must set server_name in [matrix] section of recipes.yaml" unless $server_name;

    my $admin_user = $opts{admin_user} || 'admin';
    $opts{admin_user} = $admin_user;

    my $admin_password = $opts{admin_password};
    die "Must set admin_password in [matrix] section of recipes.yaml" unless $admin_password;

    # Email config
    my $smtp_host = $opts{smtp_host};
    die "Must set smtp_host in [matrix] section of recipes.yaml" unless $smtp_host;

    my $smtp_port = $opts{smtp_port} || 465;
    $opts{smtp_port} = $smtp_port;

    my $smtp_user = $opts{smtp_user};
    die "Must set smtp_user in [matrix] section of recipes.yaml" unless $smtp_user;

    my $smtp_pass = $opts{smtp_pass};
    die "Must set smtp_pass in [matrix] section of recipes.yaml" unless $smtp_pass;

    my $smtp_domain = $opts{smtp_domain};
    die "Must set smtp_domain in [matrix] section of recipes.yaml" unless $smtp_domain;

    my $require_transport_security = $opts{require_transport_security} // 1;
    $opts{require_transport_security} = $require_transport_security;

    # Generate registration shared secret if not provided
    unless ( $opts{registration_shared_secret} ) {
        $opts{registration_shared_secret} = join '', map { ( 'a' .. 'z', 'A' .. 'Z', 0 .. 9 )[ rand 62 ] } 1 .. 32;
    }

    $opts{ipv6} //= 1;
    $opts{ipv6} = $opts{ipv6} ? 1 : 0;

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'matrix.homeserver.yaml.tt' => 'homeserver.yaml',
        'matrix.log.yaml.tt'        => 'log.yaml',
        'matrix.nginx.tt'           => 'matrix.nginx.conf',
        'matrix.admin.nginx.tt'     => 'matrix-admin.nginx.conf',
        'matrix.synapse.service.tt' => 'matrix-synapse.service',
    );
}

sub datadirs {
    return qw{matrix matrix-admin};
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/matrix.$domain/"       => 'matrix/',
        "$install_dir/admin.matrix.$domain/" => 'admin.matrix/',
    );
}

sub tests {
    return qw{matrix.tt};
}

1;
