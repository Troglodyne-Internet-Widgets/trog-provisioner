package Provisioner::Recipe::gogs;

#ABSTRACT: Install and configure the Gogs self-hosted git service.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};
use Crypt::PRNG();

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

sub required_recipes {
    my ($self, %opts) = @_;
    my $ipv6 = $opts{ipv6} // 1;
    return (
        nginxproxy  => sub {
            (
                vhosts => {
                    80  => { ssl_redirect => 1, ipv6 => 1 },
                    443 => {
                        ssl => 1,
                        proxy_uri => 'http://127.0.0.1:3000',
                        ipv6 => $ipv6,
                    },
                },
            )
        },
    );
}

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{git curl};
    }
    die "Unsupported packager";
}

sub args {
    return (
        required   => [qw{version admin_password}],
        properties => {
            version         => { type => 'string' },
            admin_password  => { type => 'string' },
            gogs_admin      => { type => 'string', default => 'git' },
            github_users    => { type => 'array',  default => [], items => { type => 'string' } },
            github_orgs     => { type => 'array',  default => [], items => { type => 'string' } },
            github_token    => { type => 'string' },
            mirror_interval => { type => 'integer', minimum => 1, maximum => 23, default => 6 },
            secret_key      => { type => 'string', default => _seekrit() },
            ipv6            => { type => 'boolean', default => 1 },
        },
    );
}

sub _seekrit {
    return join '', map { ( 'a' .. 'z', 'A' .. 'Z', 0 .. 9 )[ Crypt::PRNG::rand( 62 ) ] } 1 .. 64;
}

sub template_files {
    return (
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

sub tests {
    return qw{gogs.tt};
}

1;
