package Provisioner::Recipe::gogs;

#ABSTRACT: Install and configure the Gogs self-hosted git service.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

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

Installs and configures the Gogs self-hosted Git service behind an nginx reverse
proxy.  If you name GitHub users or organizations, it also mirrors all their
public repositories on a schedule.

This recipe requires the C<nginxproxy> recipe.

Gogs answers at the domain itself, not at C<git.$domain>.  The vhost that
C<nginxproxy> writes answers on the domain and on the aliases that C<new_config>
gives it, and C<git> is not one of them.  The recipe keeps its files under
C<$install_dir/git.$domain>, which is a directory name and not a hostname.

The package names are in the subclass for each distribution, for example
L<Provisioner::Recipe::Ubuntu::gogs>.

=head2 %required = $recipe->required_recipes(%opts)

Requires C<nginxproxy>, with a vhost on port 80 that redirects to SSL and a vhost
on port 443 that proxies to gogs on C<127.0.0.1:3000>.  C<ipv6> in C<%opts>
turns IPv6 on or off for the port 443 vhost, and it is on by default.

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

=head2 @ports = $recipe->listens()

3000 on loopback, where nginx sends the requests for gogs.

=cut

sub listens {
    return qw{3000};
}

=head2 $bool = $recipe->is_multi_tenant()

False.  One gogs is one site.  C<DOMAIN> and C<ROOT_URL> in F<app.ini> name it,
and the repositories, the database and the sessions are all in the directory of
that domain.  A second domain on the guest rewrites all of them to point at
itself.

=cut

sub is_multi_tenant { return 0 }

=head2 %schema = $recipe->args()

The JSON schema for the configuration of this recipe.

C<secret_key> has no default, on purpose.  The key signs sessions and encrypts
2FA enrollments.  A new key on each provision logs out every user and voids
every second factor.

So the guest owns the key.  It is in F<app.ini> on the guest, and
C<remote_files> salvages that file.  Before the fragment installs a new
F<app.ini>, it takes the key out of the old one.  It makes a new key only when
there is no key.  If you set C<secret_key> in F<recipes.yaml>, that value
replaces the key on the guest.  Use this for a key that you keep somewhere else.

=cut

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

            # No default, on purpose: the guest owns the key.  See the POD above.
            secret_key => { type => 'string' },
            ipv6       => { type => 'boolean', default => 1 },
        },
    );
}

=head2 %files = $recipe->template_files()

Maps each template in F<templates/files/> to the file name that the fragment
installs: the systemd unit, F<app.ini>, the setup script and the mirror script.

=cut

sub template_files {
    return (
        'gogs.service.tt'   => 'gogs.service',
        'gogs.app.ini.tt'   => 'app.ini',
        'gogs.setup.sh.tt'  => 'gogs_setup.sh',
        'gogs.mirror.sh.tt' => 'gogs.mirror.sh',
    );
}

=head2 @dirs = $recipe->datadirs()

C<gogs>, the directory under the domain directory that receives the salvage.

=cut

sub datadirs {
    return qw{gogs};
}

=head2 %restores = $recipe->restores(%opts)

Puts the salvaged C<gogs> directory back at C<$install_dir/git.$domain>.  That
is every repository, the issue database and the users.  The C<data> target does
the restore before the target of this recipe runs.

=cut

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # No owner: this recipe makes the account after data runs, and its chown -R
    # covers the restored tree.
    return ( "$install_dir/git.$domain" => { from => "$install_dir/$domain/gogs" } );
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

Salvages all of C<$install_dir/git.$domain>.  That is every repository, the
issue database and the accounts that can push to them.  None of it can be made
again.  See C<restores> above for where it goes back.

F<custom/conf/app.ini> is in that directory, so C<SECRET_KEY> survives a
rebuild.  See C<args> above.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/git.$domain/" => 'gogs/',
    );
}

=head2 @tests = $recipe->tests()

F<gogs.tt>, the test that runs on the guest.

=cut

sub tests {
    return qw{gogs.tt};
}

=head2 %jails = $recipe->jails()

A jail that bans a host whose logins fail too often.  gogs logs nothing when a
login fails.  It answers the failed C<POST /user/login> with a 200 and the
form again, and a good one with a redirect, so the jail reads the access log
of nginx for the 200.  That log is shared by every vhost on the guest, so
another vhost that answers C<POST /user/login> with a 200 counts too.

=cut

sub jails {
    return (
        'gogs-login' => {
            filter    => '',
            backend   => 'auto',
            port      => 'http,https',
            logpath   => '/var/log/nginx/access.log',
            failregex => '^<HOST> \S+ \S+ \[\] "POST /user/login HTTP/[\d.]+" 200',
        },
    );
}

=head2 @hosts = $recipe->fetch_hosts()

GitHub, which serves the release tarballs of gogs.  See C<github_release_hosts>
in L<Provisioner::Recipe>.  Also C<api.github.com>, which F<gogs.mirror.sh> asks
for the list of repositories of each user and organization.

=cut

sub fetch_hosts {
    my ($class) = @_;

    return ( 'api.github.com', $class->github_release_hosts );
}

=head2 @classes = $recipe->cache_classes()

The classes for GitHub.  L<Provisioner::Recipe> keeps them, so that each recipe
that downloads a release does not carry its own copy.

=cut

sub cache_classes {
    my ($class) = @_;
    return $class->github_release_classes;
}

1;
