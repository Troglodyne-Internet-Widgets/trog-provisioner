package Provisioner::Recipe::gogs;

use strict;
use warnings FATAL => 'all';

use parent qw{Provisioner::Recipe};
use List::Util qw{any};

=head1 Provisioner::Recipe::gogs

=head2 SYNOPSIS

    somedomain:
        gogs:
            version: 0.13.0
            gogs_admin: git
            admin_password: somepassword
            github_users:
                - someuser
            github_orgs:
                - someorg
            github_token: ghp_xxx
            mirror_interval: 6
            ipv6: true

=head2 DESCRIPTION

Installs and configures Gogs self-hosted Git service with nginx reverse proxy.
Optionally mirrors all public repositories from specified GitHub users and orgs
on a scheduled interval.

Requires nginxproxy recipe.

NOTE: Ensure 'git' (or your chosen gogs_admin value) is included in the aliases
section of ipmap.cfg for your domain so DNS/SSL certificates work for
git.[domain].

=head3 deps

Returns system package dependencies.

=over 1

=item INPUTS: none

=item OUTPUTS: list of Debian package names

=back

=head3 validate

Validates and processes configuration options.

=over 1

=item INPUTS: %opts hash with gogs configuration

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

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{git curl};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    die "This recipe requires the nginxproxy recipe to function"
        unless any { $_ eq 'nginxproxy' } @{ $opts{modules} };

    my $version = $opts{version};
    die "Must set version in [gogs] section of recipes.yaml" unless $version;

    my $admin_password = $opts{admin_password};
    die "Must set admin_password in [gogs] section of recipes.yaml" unless $admin_password;

    $opts{gogs_admin} //= 'git';

    $opts{github_users}    //= [];
    $opts{github_orgs}     //= [];
    $opts{github_token}    //= '';
    $opts{mirror_interval} //= 6;
    die "mirror_interval in [gogs] section must be a positive integer between 1 and 23"
        unless $opts{mirror_interval} =~ /^\d+$/ && $opts{mirror_interval} >= 1 && $opts{mirror_interval} <= 23;

    unless ( $opts{secret_key} ) {
        $opts{secret_key} = join '', map { ( 'a' .. 'z', 'A' .. 'Z', 0 .. 9 )[ rand 62 ] } 1 .. 64;
    }

    $opts{ipv6} //= 1;
    $opts{ipv6} = $opts{ipv6} ? 1 : 0;

    return %opts;
}

sub template_files {
    return (
        'gogs.nginx.tt'     => 'gogs.nginx.conf',
        'gogs.service.tt'   => 'gogs.service',
        'gogs.app.ini.tt'   => 'app.ini',
        'gogs.setup.sh.tt'  => 'gogs_setup.sh',
        'gogs.mirror.sh.tt' => 'gogs.mirror.sh',
    );
}

sub datadirs {
    return qw{gogs};
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/git.$domain/" => 'gogs/',
    );
}

1;
