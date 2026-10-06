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
        },
    );
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
        'claude.settings.json.tt' => 'claude.settings.json',
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

The command is rsync and not an installed script, so that it also runs on a
guest built before this recipe salvaged memories.  Every guest has rsync,
because the salvage itself runs it there.  On a guest with no
F<.claude/projects>, it stages nothing and succeeds.

=cut

sub remote_prepare {
    my ( $self, $install_dir, $domain ) = @_;
    my $home = "$install_dir/$domain";

    # No slash after projects, because --delete-missing-args covers only a
    # source that names a file or directory, not the contents of one.  The
    # include of /projects itself, because rsync takes a missing source for a
    # file, and the exclude of everything else would keep its copy.
    return ("rsync -a --delete --delete-missing-args --prune-empty-dirs --include='/projects' --include='*/' --include='/projects/*/memory/***' --exclude='*' '$home/.claude/projects' '$home/.claude-memory-salvage/'");
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/$domain/.claude.json"            => '.claude.json',
        "$install_dir/$domain/.claude-memory-salvage/" => 'claude/memory/',
    );
}

=head2 %restores = $recipe->restores(%opts)

The salvaged memories go back to F<.claude/projects>, owned by the admin, whose
C<HOME> the directory of the domain is.  On a guest that already has memories,
C<restore_state> keeps them.

=cut

sub restores {
    my ( $self, %opts ) = @_;
    my ( $install_dir, $domain, $admin_user ) = @opts{qw{install_dir domain admin_user}};

    return ( "$install_dir/$domain/.claude/projects" => { from => "$install_dir/$domain/claude/memory/projects", owner => "$admin_user:$admin_user" } );
}

sub tests {
    return qw{claude.tt};
}

1;
