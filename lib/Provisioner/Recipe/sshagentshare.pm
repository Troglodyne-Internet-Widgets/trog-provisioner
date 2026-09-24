package Provisioner::Recipe::sshagentshare;

#ABSTRACT: Share the ssh agents of every login of a user among all of their shells.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::sshagentshare

=head2 SYNOPSIS

    somedomain:
        sshagentshare:

=head2 DESCRIPTION

A tmux pane keeps the C<SSH_AUTH_SOCK> of the login that started it.  When
that login ends, sshd removes the socket, and every pane loses its agent,
although the user can still have another login with a live agent.

This recipe gives every interactive bash of every user one stable
C<SSH_AUTH_SOCK>, F<~/.ssh/agent.sock>.  That is a link to a live agent, and the
shells move the link when its agent goes away:

=over 4

=item * Each shell remembers the agent that it started with, as a link in
F<~/.ssh/agents/>, and points F<~/.ssh/agent.sock> at it.  So the newest login
gives its agent to every shell of the user.

=item * At each prompt, a shell tests whether F<~/.ssh/agent.sock> still leads
to a socket.  If it does not, the shell points it at the newest agent in
F<~/.ssh/agents/> that still answers, and removes the links to agents that do
not.

=item * When a login shell of sshd exits, F</etc/bash.bash_logout> removes the
link to its agent, and moves F<~/.ssh/agent.sock> away from it.  A tmux pane
does not do this, because the login still holds that agent.

=back

The logout hook is the fast path, and the prompt is the one that always runs.
Bash does not read F<bash.bash_logout> when a hangup or a kill ends the shell,
and that is how a login usually ends when its client machine shuts down.

A shell that already runs when the recipe installs picks up nothing.  A new
login does, and so does each new tmux pane.

=head2 FILES

=over 4

=item F</etc/sshagentshare.bash>

The functions, and the hook in C<PROMPT_COMMAND>.

=item F</etc/profile.d/sshagentshare.sh>

Sources the file above in an interactive login bash.  tmux starts each pane as
a login shell, so a pane reads it too.  It runs before F<~/.bashrc>, so a dotfile
that starts its own agent when none answers finds the shared one first.

=item F</etc/bash.bash_logout>

Gets one line that calls the logout hook.  No package owns this file.

=back

=head2 deps

C<ssh-add>, to ask whether an agent answers.

=cut

sub template_files {
    return (
        'sshagentshare.bash.tt'    => 'sshagentshare.bash',
        'sshagentshare.profile.tt' => 'sshagentshare.profile',
    );
}

sub tests {
    return qw{sshagentshare.tt};
}

1;
