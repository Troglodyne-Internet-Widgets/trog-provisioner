package Provisioner::Recipe::clod;

#ABSTRACT: Install and run App::Clod, the hub-and-spoke GitHub bot.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use B();
use Mojo::JSON();
use Text::Xslate();

use Provisioner::Recipe::claude();
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

            # Let an authorized user have the bot make a repository in an
            # organization of spoke_orgs, one per request.  The token must be
            # able to make repositories there.
            create_repos: true

            # How many follow-up issues one request may file.  0 turns it off.
            follow_up_max: 3
            workers:        2
            spoke_modules:
                - "Test2::V0"

            # Permission rules that the runs which change a repository get,
            # beyond the defaults of App::Clod.  The triage run never does.
            extra_tools:
                - "Bash(bin/provision:*)"

            # Told to every spoke run, and to triage, so that it knows how
            # each spoke tests.
            spoke_prompt: |
                Run prove -lr t before you commit.

            # Repositories of which every spoke run gets a fresh worktree of
            # its own, such as a tool that the runs use.
            tool_spokes:
                - "yourorg/tool"

            # The account that every claude run runs as, so that the agent
            # cannot read the token of the bot.  See THE AGENT ACCOUNT.
            agent_user: "clod-agent"

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
plugins that they enable.  Set C<user> for the domain, so that the bot runs as
an account without the sudo of the admin.  The bot runs unattended, and a run
that goes wrong can do whatever its account can.  The claude recipe gives
F<.claude> to C<user> when the domain names one, and to the admin only when
it does not.

Those settings apply to every C<claude> run in that C<HOME>, and so to the
triage run too, which only reads.  A permission for the runs that change a
repository goes in C<extra_tools> instead, which App::Clod gives to those
runs alone.

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

=head2 THE AGENT ACCOUNT

Without C<agent_user>, every C<claude> run of the bot runs as C<user>, the
account of the worker.  App::Clod keeps C<GH_TOKEN> out of the environment of
claude, but a process can read F</proc/$pid/environ> of every process of its
own account, and the worker has the token in its environment.  The default
tools of a spoke run include C<Bash(perl:*)>, so the agent could read it.

With C<agent_user>, the bot runs claude as that account instead, through
sudo.  The account cannot read the environment of the worker, F<clod.env> or
F<clod.conf>.  The recipe:

=over 4

=item * Hands the name to L<Provisioner::Recipe::claude> as C<restricted_user>.
That recipe makes the account and its home, C<agent_home>, with the plugins
and settings of the agent of the domain, but without its bot.  See
L<Provisioner::Recipe::claude/A RESTRICTED AGENT>.

=item * Lets C<user> run any command as C<agent_user>, with C<SETENV> and no
password, in F</etc/sudoers.d/clod-E<lt>userE<gt>>.  The grant goes from the
account of the worker down to an account that holds less, so it gives the
worker nothing that it does not already have.  C<SETENV> lets App::Clod pass
C<CLAUDE_CODE_OAUTH_TOKEN> through the environment, never through the argument
list, which C<ps> shows to every account.  The file also sets the umask of a
command that runs as C<agent_user> to C<0007>, because sudo combines its own
umask with that of the worker.  Without C<agent_user>, the file holds no
grant, so a provision takes back the grant of an earlier one.

=item * Gives the workspace to the group of C<agent_user>, setgid, with mode
C<2770>, and puts C<user> in that group.  The worker gets C<UMask=0007>.  So
claude can commit in a work tree that the worker made, and the worker can push
the commit and remove the work tree.  The group of C<user> stays the group of
F<clod.env> and F<clod.conf>, and the agent is not in it.  F<clod-share.sh>
does this in the postrun, before the services restart, because the target of
the claude recipe runs after this one, and makes the account.

=item * Writes C<run_as> into the C<claude> section of F<clod.conf>.

=back

If the agent builds guests to test on, with L<Provisioner::Recipe::trogrunner>
on the same domain, name C<agent_user> as the C<provision_user> of that recipe
too.  Then the agent gets the key that the hypervisors trust, and the worker
does not.  See L<Provisioner::Recipe::trogrunner/THE PROVISIONING ACCOUNT>.

C<deps> is in L<Provisioner::Recipe::Ubuntu::clod>.

=cut

# A word that goes into clod.conf between single quotes, and into a quoted
# string of the guest test.  GitHub logins and repository names fit it.
my %NAME = ( type => 'string', pattern => '^[A-Za-z0-9_.-]+$' );
my %REPO = ( type => 'string', pattern => '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' );

# A permission rule of Claude Code: a tool, or a tool and what it may do.
# perl_string quotes it, so this only holds it to that shape, on one line.
my $RULE = q{^[A-Za-z][A-Za-z0-9_]*(?:[(][^\n\r'"\\\\]+[)])?\z};

sub args {
    return (
        type     => 'object',
        required => [qw{bot github_token claude_oauth_token dashboard_password_sha256}],
        anyOf    => [ { required => ['spokes'] }, { required => ['spoke_orgs'] } ],

        # App::Clod makes a repository in an org of spoke_orgs, and dies without one.
        allOf      => [ { anyOf => [ { properties => { create_repos => { type => 'boolean', enum => [Mojo::JSON::false] } } }, { required => ['spoke_orgs'] } ] } ],
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
                items       => {%REPO},
                description => 'The repositories that the bot works on, as Owner/Name.',
            },
            tool_spokes => {
                type        => 'array',
                default     => [],
                items       => {%REPO},
                description => 'Repositories, as Owner/Name, of which every spoke run gets a fresh worktree of its own.',
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
            create_repos  => { type => 'boolean', default => 0,  description => 'Whether an authorized user can have the bot make a new repository, in an organization of spoke_orgs, one per request.  Needs spoke_orgs, and a token that may make repositories there.' },
            follow_up_max => { type => 'integer', minimum => 0,  description => 'How many follow-up issues one request may have the bot file.  0 turns it off.  Unset is the default of App::Clod.' },
            spoke_modules => { type => 'array',   default => [], items       => { type => 'string' }, description => 'Modules that the tests of the spokes need, beyond what App::Clod needs.  The perl recipe installs them.' },

            extra_tools => {
                type        => 'array',
                default     => [],
                items       => { type => 'string', pattern => $RULE },
                description => 'Claude Code permission rules, such as Bash(bin/provision:*), that App::Clod adds to its allowed_tools for the runs that change a repository, and never for triage.',
            },
            spoke_prompt => { type => 'string', minLength => 1,                     description => 'Text that App::Clod appends to the system prompt of every spoke run, and shows to triage, so that it knows how each spoke tests.' },
            agent_user   => { type => 'string', pattern   => '^[a-z_][a-z0-9_-]*$', description => 'The account that every claude run of the bot runs as, through sudo, so that the agent cannot read the token of the bot.  See THE AGENT ACCOUNT.' },
        },
    );
}

=head2 %required = $recipe->required_recipes(%opts)

C<perl>, which installs what the checkout needs and C<spoke_modules>.
C<nginxproxy>, which serves the socket.  C<claude>, which installs the program
that does the work, and makes the C<agent_user> as its C<restricted_user>.

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
        claude     => sub {
            my (%opts) = @_;
            return defined $opts{agent_user} ? ( restricted_user => $opts{agent_user} ) : ();
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<agent_home>, the home that L<Provisioner::Recipe::claude> makes for
C<agent_user>, when the domain names one.

Dies when C<user> is not a plain account name.  It goes into a sudoers line
and into the name of F</etc/sudoers.d/clod-E<lt>userE<gt>>, and sudo skips a
file whose name has a dot in it.  C<user> is a global, which the schema of a
recipe does not declare a second time, so the check is here.

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    die "clod: the user of $opts{domain}, $opts{user}, is not a name that a sudoers line and the name of a file in sudoers.d can both hold.\n"
      unless $opts{user} =~ m/\A[[:lower:]_][[:lower:][:digit:]_-]*\z/;
    $opts{agent_home} = Provisioner::Recipe::claude::->restricted_home( %opts, restricted_user => $opts{agent_user} ) if defined $opts{agent_user};
    return %opts;
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

=head2 %formatters = $recipe->formatters()

C<perl_string>, which F<clod.conf.tt> quotes free text with.  L<B/perlstring>
escapes every quote, C<$>, C<@>, backslash and control character, so no text
can end the string or interpolate into it.  It is raw, so Xslate does not
escape it for HTML on top.

=cut

sub formatters {
    return ( perl_string => Text::Xslate::html_builder( sub ($text) { return B::perlstring($text) } ) );
}

sub template_files {
    return (
        'clod.conf.tt'           => 'clod.conf',
        'clod.env.tt'            => 'clod.env',
        'clod.service.tt'        => 'clod.service',
        'clod-worker.service.tt' => 'clod-worker.service',
        'clod.salvage.sh.tt'     => 'clod-salvage.sh',
        'clod.sudoers.tt'        => 'clod.sudoers',
        'clod.share.sh.tt'       => 'clod-share.sh',
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
