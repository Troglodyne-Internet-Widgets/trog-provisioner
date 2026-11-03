package Provisioner::Recipe::claude;

#ABSTRACT: Install claude-code globally, with rtk in front of its Bash tool.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::claude

=head2 SYNOPSIS

    somedomain:
        claude:

    # Or with a version of rtk to pin:
    somedomain:
        claude:
            rtk_version: "v0.49.0"

    # Or with a GitHub bot that the agent acts as, and the reviewer of its
    # pull requests:
    somedomain:
        claude:
            github_user:  "yourname-bot"
            github_token: "secret:github/yourname-bot/password"
            git_email:    "bot@example.test"
            pr_assignee:  "yourname"

=head2 DESCRIPTION

Install claude-code globally with C<npm>, if the guest has no C<claude> command.

The recipe also installs F<.claude/settings.json> in the directory of the
domain under C<install_dir>.  The settings enable the perl-slop and
C<simple-english> plugins on every guest.  They enable more plugins when the
domain runs the C<perl> or C<perllsp> recipe.  Each enabled plugin comes with
the marketplace that publishes it.

The recipe salvages F<.claude.json> from that directory on the old guest, and
the memories that the agent saved, but not its transcripts.  See
C<remote_prepare>.

SLOP in the ice machine.

The directory of the domain is the C<HOME> of the agent, so these are the
settings of the user, which apply wherever a session starts.  The settings of a
project are the wrong place for the two sections below: a repository must not
be able to declare itself trusted, and Claude Code did not read C<autoMode>
from them when this was tested.

=head2 AUTO MODE

Auto mode lets a classifier approve or refuse each action of the agent.  Its
configuration says where the trust boundary is: which organizations,
repositories and hosts belong to the operator.  That is data about the
operator, not about the recipe, so the recipe ships none.

To give a domain one, put the value of C<autoMode> in
F<claude.auto-mode.json> in the data directory of the domain.  From a settings
file that already has one:

    jq .autoMode ~/.claude/settings.json > $data_dir/claude.auto-mode.json

C<claude_settings auto-mode> puts it in place of C<autoMode> in the settings on
the guest, and every other key stays.  A domain with no such file gets the
defaults of Claude Code.

=head2 THE CHECKOUTS OF ADMINCODE

On a guest that also runs L<Provisioner::Recipe::admincode>, each repository
that it clones becomes an entry of C<permissions.additionalDirectories>, which
is what C</add-dir> saves.  So the agent can work in any of them, and loads the
skills in their F<.claude/skills>, wherever its session starts.  The admincode
fragment queues C<claude_settings add-repos> as a postrun task, because it
knows the C<basedir>, and this target can run after its own.

=head2 A BOT FOR THE AGENT

GitHub tells nobody of what they did themselves.  So a pull request that the
agent opens with the login of the operator never reaches the inbox of the
operator.  With C<github_user>, C<github_token> and C<git_email>, the agent acts
as a bot of its own:

=over 4

=item * L<Provisioner::Recipe::github> writes the login of the bot into
F<.claude/gh> in the directory of the domain, for the service C<user>, who runs
the agent.  The login that the account has in F<~/.config/gh> stays its own.

=item * The settings give each command of the agent an C<env>.  C<GH_CONFIG_DIR>
names that directory, the four C<GIT_AUTHOR_*> and C<GIT_COMMITTER_*> variables
name the bot, and C<GIT_CONFIG_*> makes git reach C<git@github.com:> over https.
So a push goes with the token of the bot through the credential helper of gh,
and not with the ssh key of the admin.

=item * C<pr_assignee> becomes C<PERL_SLOP_ASSIGNEE>, which the perl-slop plugin
holds each C<gh pr create> of the agent to.  A pull request from the bot that is
assigned to the operator reaches the inbox of the operator.

=back

A domain that runs L<Provisioner::Recipe::koan> logs its own bot in through
C<github>, so it names none here.

=head2 A RESTRICTED AGENT

A program that runs claude unattended, such as L<Provisioner::Recipe::clod>,
can run it as an account of its own, so that the agent cannot read what the
program holds: a process can read F</proc/$pid/environ> of every process of
its own account.  With C<restricted_user>, the recipe makes that account, and
a second home for it, C<restricted_home>: F<agents/E<lt>nameE<gt>> in the
directory of the domain.

The account is a system account with C<nologin> and a group of the same name.
The data recipe makes the directory of the domain C<0750>, so an ACL lets the
account pass through it, and it cannot list it.  Each path under it is then
open to the account only as far as its own mode allows.
Its home gets the same plugins and the same rtk hook, but none of the C<env> of
L</A BOT FOR THE AGENT> and no auto mode.  Its agent does what the program that
runs it allows, and it must not act as the bot.  Its git configuration sets
C<safe.directory> to C<*>, because it works in checkouts that the program owns,
and git refuses to work in a repository that another account owns.  The recipe
salvages nothing of that home.

The recipe grants the account nothing.  The program that runs claude as it
needs a sudo rule for that, which the recipe of the program writes.

=head2 RTK

L<rtk|https://github.com/rtk-ai/rtk> filters the output of a shell command
before the agent reads it, which is most of what an agent spends its context
on.  It goes in as the C<.deb> that its release publishes, so the binary is one
file in F</usr/bin> that every account on the guest can run, and C<dpkg> knows
which version is there.

C<rtk init -g --auto-patch> registers it: a C<PreToolUse> hook on the Bash tool
that rewrites a command to C<rtk E<lt>commandE<gt>>.  The C<--auto-patch> is
what makes it answer its own questions -- the interactive form asks two, and a
makefile has nobody to answer them.

It runs B<after> the settings file is installed, because it edits that file:
it adds its hook to the JSON that is already there and leaves the enabled
plugins alone.  Run again it says the hook is already present and changes
nothing, so a second provision costs nothing.  Installing it the other way
round would work once and then be overwritten by the next build.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            rtk_version => {
                type        => 'string',
                default     => 'v0.49.0',
                description => 'The rtk release to install, as its tag.  The .deb of that release is what goes on the guest.',
            },

            # Each of these goes into the JSON of the settings and into a quoted
            # string of the guest test, so each is held to characters that need
            # no quoting in either.
            github_user  => { type => 'string', pattern    => '^[A-Za-z0-9-]+$',                description => 'The GitHub account of a bot that the agent acts as.  See A BOT FOR THE AGENT.' },
            github_token => { type => 'string', 'x-secret' => 1,                                description => 'A personal access token for that account.' },
            git_email    => { type => 'string', pattern    => q{^[^\\s"'\\\\]+@[^\\s"'\\\\]+$}, description => 'The address that the commits of the bot carry.  GitHub links a commit to the account that has this address.' },
            pr_assignee  => { type => 'string', pattern    => '^[A-Za-z0-9-]+$',                description => 'The login that each pull request of the agent is assigned to, as PERL_SLOP_ASSIGNEE.' },

            restricted_user => {
                type        => 'string',
                pattern     => '^[a-z_][a-z0-9_-]*$',
                description => 'An account to make, with a home and settings of its own, that a program runs claude as.  See A RESTRICTED AGENT.',
            },
        },
    );
}

=head2 %required = $recipe->required_recipes(%opts)

C<github>, for the login of the bot, when the domain names one.  It names no
C<account>, so the login goes to the account that C<github> defaults to: the
service C<user>, or the admin on a domain that names none.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    return if !$opts{github_user};

    return (
        github => sub {
            my (%given) = @_;
            return (
                github_user  => $given{github_user},
                github_token => $given{github_token},
                config_dir   => $self->bot_config_dir(%given),
            );
        },
    );
}

=head2 $dir = $recipe->bot_config_dir(%opts)

Where the login of the bot goes: F<.claude/gh> in the directory of the domain.

=cut

sub bot_config_dir {
    my ( $self, %opts ) = @_;
    return "$opts{install_dir}/$opts{domain}/.claude/gh";
}

=head2 $dir = $recipe->restricted_home(%opts)

The home of C<restricted_user>: F<agents/E<lt>restricted_userE<gt>> in the
directory of the domain.

=cut

sub restricted_home {
    my ( $self, %opts ) = @_;
    return "$opts{install_dir}/$opts{domain}/agents/$opts{restricted_user}";
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<gh_config_dir>, the directory of C<bot_config_dir>, when the domain
names a bot.  Dies when it names only some of C<github_user>, C<github_token>
and C<git_email>.

Adds C<restricted_home> when the domain names a C<restricted_user>.  Dies when
that is the service C<user> or the admin, because the point of the account is
that it is neither.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my $given = grep { defined $opts{$_} } qw{github_user github_token git_email};
    die "claude: github_user, github_token and git_email go together.  Without one of them the bot cannot log in, or its commits name nobody.\n"
      if $given && $given != 3;

    $opts{gh_config_dir} = $self->bot_config_dir(%opts) if $given;

    if ( defined $opts{restricted_user} ) {
        my %taken = map { $_ => 1 } grep { defined } @opts{qw{user admin_user}};
        die "claude: restricted_user $opts{restricted_user} is an account that already runs things here.  It must be an account of its own.\n"
          if $taken{ $opts{restricted_user} };
        $opts{restricted_home} = $self->restricted_home(%opts);
    }
    return %opts;
}

=head2 @hosts = $recipe->fetch_hosts()

Where the rtk release comes from.  The npm registry is not here: the C<perl>
and C<nvm> recipes name it, and this one installs through whatever npm is
configured with.

=cut

sub fetch_hosts {
    my ($self) = @_;
    return $self->github_release_hosts();
}

=head2 @classes = $recipe->cache_classes()

The classes for a GitHub release, so that a cache keeps the C<.deb> rather than
fetching it once per guest.

=cut

sub cache_classes {
    my ($self) = @_;
    return $self->github_release_classes();
}

sub template_files {
    return (
        'claude.settings.json.tt'            => 'claude.settings.json',
        'claude.restricted.settings.json.tt' => 'claude.restricted.settings.json',
    );
}

=head2 @commands = $recipe->remote_prepare($install_dir, $domain)

Copies the F<memory/> directory of each project under F<.claude/projects> into
F<.claude-memory-salvage>, beside it in the directory of the domain, and
nothing else, so that C<remote_files> fetches the memories and not the rest of
that directory.  The rest is the transcript of every session and the output of
its tools: hundreds of megabytes, and whatever passed through a session, secrets
included.  It names what to keep, because a salvage can only exclude, and an
exclude list lets through whatever Claude Code starts to keep there next.

It also copies F<.claude.json> into F<.claude-state-salvage>, because
C<remote_files> salvages directories, not files.

The commands are rsync and not an installed script, so that it also runs on a
guest built before this recipe salvaged memories.  Every guest has rsync,
because the salvage itself runs it there.  On a guest with no
F<.claude/projects>, it stages nothing and succeeds, and the same goes for a
guest with no F<.claude.json>.  A staged copy of either that is gone from the
guest goes from the staging directory too.

=cut

sub remote_prepare {
    my ( $self, $install_dir, $domain ) = @_;
    my $home = "$install_dir/$domain";

    # No slash after projects, because --delete-missing-args covers only a
    # source that names a file or directory, not the contents of one.  The
    # include of /projects itself, because rsync takes a missing source for a
    # file, and the exclude of everything else would keep its copy.
    return (
        "rsync -a --delete --delete-missing-args --prune-empty-dirs --include='/projects' --include='*/' --include='/projects/*/memory/***' --exclude='*' '$home/.claude/projects' '$home/.claude-memory-salvage/'",
        "rsync -a --delete-missing-args '$home/.claude.json' '$home/.claude-state-salvage/'",
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/$domain/.claude-memory-salvage/" => 'claude/memory/',
        "$install_dir/$domain/.claude-state-salvage/"  => 'claude/state/',
    );
}

=head2 %restores = $recipe->restores(%opts)

The salvaged memories go back to F<.claude/projects>, and F<.claude.json> to the
directory of the domain with mode 0600, because it holds the account state of
whoever runs Claude Code there.  Both belong to the service C<user>, whose
C<HOME> the directory of the domain is, and to the group of the admin.  On a
domain that names no service user, they belong to the admin.  On a guest that
already has either, C<restore_state> keeps it.

=cut

sub restores {
    my ( $self, %opts ) = @_;
    my ( $install_dir, $domain, $admin_user ) = @opts{qw{install_dir domain admin_user}};

    # user falls back to admin_user as validate does, because required_recipes
    # asks for this before validation.
    my $user = $opts{user} // $admin_user;

    return (
        "$install_dir/$domain/.claude/projects" => { from => "$install_dir/$domain/claude/memory/projects",    owner => "$user:$admin_user" },
        "$install_dir/$domain/.claude.json"     => { from => "$install_dir/$domain/claude/state/.claude.json", owner => "$user:$admin_user", mode => '0600' },
    );
}

sub tests {
    return qw{claude.tt};
}

1;
