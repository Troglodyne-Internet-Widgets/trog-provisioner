package Provisioner::Recipe::gogs;

#ABSTRACT: Install and configure the Gogs self-hosted git service.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

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

The whole of C<git.$domain>, which is every repository, the issue database and
the accounts that can push to any of it.  None of it is regenerable, and the
fragment puts it back with C<restore_state> before gogs is started.

C<custom/conf/app.ini> comes along inside it, which is how C<SECRET_KEY>
survives a rebuild: see L</args>.

=over 1

=item INPUTS: $install_dir, $domain

=item OUTPUTS: hash of remote path => local backup path

=back

=head3 args

C<secret_key> has no default, deliberately.  It signs sessions and encrypts 2FA
enrolments, and it used to be minted afresh by every C<bin/new_config> run --
which is a rotation rather than a default: re-provisioning logged everybody out
and voided every second factor, unless an operator had thought to pin the key in
C<recipes.yaml>.

So the guest owns it.  It already lives in C<app.ini> there, C<remote_files>
brings that file back, and the fragment lifts the key out of whatever C<app.ini>
is on the guest before overwriting it -- minting one only when there genuinely is
none.  Setting it here still works and still wins, for a key an operator is
keeping somewhere else.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    my $ipv6 = $opts{ipv6} // 1;
    return (
        nginxproxy => sub {
            (
                vhosts => {
                    80  => { ssl_redirect => 1, ipv6 => 1 },
                    443 => {
                        ssl       => 1,
                        proxy_uri => 'http://127.0.0.1:3000',
                        ipv6      => $ipv6,
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

            # No default.  This was `default => _seekrit()`, evaluated once per
            # new_config run, so every re-provision handed gogs sixty-four fresh
            # characters and took every session and every 2FA enrolment with it.
            # The guest owns the key; the fragment carries it forward.
            secret_key => { type => 'string' },
            ipv6       => { type => 'boolean', default => 1 },
        },
    );
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
