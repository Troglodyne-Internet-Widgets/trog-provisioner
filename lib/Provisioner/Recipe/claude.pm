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

The recipe salvages F<.claude.json> from that directory on the old guest.

SLOP in the ice machine.

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

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/$domain/.claude.json" => '.claude.json',
    );
}

sub tests {
    return qw{claude.tt};
}

1;
