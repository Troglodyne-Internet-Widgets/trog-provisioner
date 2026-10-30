package Provisioner::Recipe::clod;

#ABSTRACT: Install and run App::Clod, the hub-and-spoke GitHub bot.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Utils();

# One copy for args and fetch_hosts, so that two copies do not drift apart.
our $DEFAULT_REPO = 'https://github.com/Troglodyne-Internet-Widgets/App-Clod.git';

=head1 Provisioner::Recipe::clod

=head2 SYNOPSIS

    somedomain:
        clod:
            # The GitHub login of the bot, and a classic token of that
            # account with the repo scope, which the inbox also needs.
            bot:          "yourname-bot"
            github_token: "secret:github/yourname-bot/password"

            # The long-lived OAuth token that `claude setup-token` makes on a
            # workstation.
            claude_oauth_token: "secret:claude/yourname-bot/password"

            # The repositories that the bot works on, as Owner/Name.  Give
            # spokes, spoke_orgs or both.
            spokes:
                - "otherorg/app"

            # Organizations whose public repositories are all spokes, except
            # forks and archived ones.  App::Clod lists them every fifteen
            # minutes, so a new repository needs no provision.
            spoke_orgs:
                - "yourorg"

            # Whose assignments, review requests and mentions the bot acts on.
            authorized_users:
                - "yourname"

            # The users and organizations whose repositories are ours.  A fix
            # that belongs anywhere else goes back to a person.
            owners:
                - "yourorg"

            # HTTP basic authentication for the health page.  The hash is the
            # output of: printf %s 'the password' | sha256sum
            dashboard_password_sha256: "secret:clod/dashboard/password"

            # Optional.
            dashboard_user: "admin"
            workers:        2
            spoke_modules:
                - "Test2::V0"

=head2 DESCRIPTION

Installs L<App::Clod|https://github.com/Troglodyne-Internet-Widgets/App-Clod>
and runs it as two systemd services, as the service C<user> of the domain:

=over 4

=item * C<clod-E<lt>domainE<gt>> runs C<clod daemon>.  It serves the health
page and Minion::Admin on a unix socket, and L<Provisioner::Recipe::nginxproxy>
serves that socket on port 443.  Port 80 redirects to it.

=item * C<clod-worker-E<lt>domainE<gt>> runs C<clod minion worker>.  It reads
the inbox of the bot and does the work, with C<workers> jobs at a time.

=back

The services run from a checkout of C<repo_url>.  L<Provisioner::Recipe::perl>
installs what the checkout needs, with its C<dzil> step.  That step also
installs the author dependencies of App::Clod, which include C<perltidy>,
C<perlcritic> and the Troglodyne policies.  The git hooks of the spokes run
those tools when the bot commits in a C<git worktree>.

To add a spoke, give the bot write access to it.  If the bot is a member of
an organization in C<spoke_orgs>, with write access through a team, a new
public repository there needs nothing else.  Otherwise add it to C<spokes>
and provision again.  If the tests of a spoke need modules
that App::Clod does not, name them in C<spoke_modules>.

L<Provisioner::Recipe::claude> installs the C<claude> program and the settings
in the directory of the domain.  That directory is the C<HOME> of both
services, so every C<claude> run of the bot uses those settings and the
plugins that they enable.  The claude recipe gives F<.claude> to the admin.
So leave C<user> unset, and the services run as the admin, who can write
there.

The layout on the guest:

    [install_dir]/[domain]/App-Clod/    the checkout
    [install_dir]/[domain]/clod.conf    the configuration, 0640 root:[user]
    [install_dir]/[domain]/clod.env     GH_TOKEN and CLAUDE_CODE_OAUTH_TOKEN, 0640 root:[user]
    [install_dir]/[domain]/clod-state/  the Minion database
    [install_dir]/[domain]/workspace/   the mirrors, the work trees and the hub of the bot
    [install_dir]/[domain]/run/         the socket, 2750 [user]:www-data

The Minion database holds every job, the history on the health page, and the
claims that stop the bot from taking one notification twice.  So it survives a
rebuild of the guest.  See C<remote_prepare>.  The workspace does not, because
the bot fetches the mirrors again.

C<deps> is in L<Provisioner::Recipe::Ubuntu::clod>.

=cut

# A word that goes into clod.conf between single quotes, and into a quoted
# string of the guest test.  GitHub logins and repository names fit it.
my %NAME = ( type => 'string', pattern => '^[A-Za-z0-9_.-]+$' );

sub args {
    return (
        type       => 'object',
        required   => [qw{bot github_token claude_oauth_token dashboard_password_sha256}],
        anyOf      => [ { required => ['spokes'] }, { required => ['spoke_orgs'] } ],
        properties => {
            repo_url    => { type => 'string', default => $DEFAULT_REPO, description => 'Where to clone App::Clod from.' },
            repo_branch => { type => 'string', default => 'master',      description => 'The branch of repo_url that the services run.' },

            bot                => { %NAME, description => 'The GitHub login of the bot.' },
            github_token       => { type => 'string', 'x-secret' => 1,                                description => 'A classic token of the bot account, with the repo scope.' },
            claude_oauth_token => { type => 'string', 'x-secret' => 1,                                description => 'The long-lived OAuth token that claude setup-token makes.' },
            bot_email          => { type => 'string', pattern    => q{^[^\\s"'\\\\]+@[^\\s"'\\\\]+$}, description => 'The address of the commits of the bot.  Unset is the GitHub no-reply address of the bot.' },

            spokes => {
                type        => 'array',
                minItems    => 1,
                items       => { type => 'string', pattern => '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' },
                description => 'The repositories that the bot works on, as Owner/Name.',
            },
            spoke_orgs => {
                type        => 'array',
                minItems    => 1,
                items       => {%NAME},
                description => 'Organizations whose public repositories are spokes, except forks and archived ones.  App::Clod lists them every fifteen minutes.',
            },
            authorized_users => { type => 'array', default => [], items => {%NAME}, description => 'The logins whose assignments, review requests and mentions the bot acts on.  The bot ignores everyone else.' },
            owners           => { type => 'array', default => [], items => {%NAME}, description => 'The users and organizations whose repositories are ours.  A fix that belongs anywhere else goes back to a person.' },

            dashboard_user            => { %NAME, default => 'admin', description => 'The user name of HTTP basic authentication for the health page.' },
            dashboard_password_sha256 => { type => 'string', 'x-secret' => 1, pattern => '^[0-9a-f]{64}$', description => q{The SHA-256 of the password of the health page, in lowercase hex: printf %s 'the password' | sha256sum} },

            workers       => { type => 'integer', default => 2,  minimum     => 1, description => 'How many jobs the worker runs at once.  Each job can be a claude run.' },
            poll_interval => { type => 'integer', minimum => 60, description => 'The least number of seconds between two reads of the inbox.  Unset is the default of App::Clod.' },
            spoke_modules => { type => 'array',   default => [], items       => { type => 'string' }, description => 'Modules that the tests of the spokes need, beyond what App::Clod needs.  The perl recipe installs them.' },
        },
    );
}

=head2 %required = $recipe->required_recipes(%opts)

C<perl>, which installs what the checkout needs and C<spoke_modules>.
C<nginxproxy>, which serves the socket.  C<claude>, which installs the program
that does the work.

=cut

sub required_recipes {
    return (
        # The perl target runs after this fragment makes the checkout, and
        # before the postrun starts the services.  See cpan_deps in
        # Provisioner::Recipe::perl.  Before validation, so no default yet.
        perl => sub {
            my (%opts) = @_;
            my @modules = @{ $opts{spoke_modules} // [] };
            return (
                cpan_deps => [
                    { dzil => "$opts{install_dir}/$opts{domain}/App-Clod" },
                    ( @modules ? { install => \@modules } : () ),
                ],
            );
        },
        nginxproxy => sub { return ( proxy_uri => 'run/clod.sock' ) },
        claude     => sub { return () },
    );
}

=head2 @commands = $recipe->remote_prepare($install_dir, $domain)

Runs F<clod-salvage.sh>, which copies the Minion database into
F<.clod-salvage> with the C<.backup> of C<sqlite3>.  The worker writes the
database all the time, so a plain copy can take half of a transaction.  On a
guest without the database, the command fails, and the salvage keeps what it
had.

=cut

sub remote_prepare {
    my ( $self, $install_dir, $domain ) = @_;
    return ("$install_dir/$domain/clod-salvage.sh");
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

The copy that C<remote_prepare> made.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return ( "$install_dir/$domain/.clod-salvage/" => 'clod-salvage/' );
}

=head2 %restores = $recipe->restores(%opts)

The salvaged database goes back to F<clod-state>, owned by the service C<user>.

=cut

sub restores {
    my ( $self, %opts ) = @_;
    my ( $install_dir, $domain, $admin_user ) = @opts{qw{install_dir domain admin_user}};
    my $user = $opts{user} // $admin_user;
    return ( "$install_dir/$domain/clod-state/minion.db" => { from => "$install_dir/$domain/clod-salvage/minion.db", owner => "$user:$admin_user", mode => '0640' } );
}

sub template_files {
    return (
        'clod.conf.tt'           => 'clod.conf',
        'clod.env.tt'            => 'clod.env',
        'clod.service.tt'        => 'clod.service',
        'clod-worker.service.tt' => 'clod-worker.service',
        'clod.salvage.sh.tt'     => 'clod-salvage.sh',
    );
}

sub tests {
    return qw{clod.tt};
}

=head2 @hosts = $recipe->fetch_hosts(%opts)

The host of C<repo_url>, which is GitHub for the default.

=cut

sub fetch_hosts {
    my ( $self, %opts ) = @_;
    return Provisioner::Utils::host_of( $opts{repo_url} // $DEFAULT_REPO ) || ();
}

1;
