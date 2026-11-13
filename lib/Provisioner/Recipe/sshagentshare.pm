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
to a socket that something listens on.  A socket file can outlive its agent,
so the test looks the path up in F</proc/net/unix> as well.  If nothing
listens, the shell points the link at the newest agent in F<~/.ssh/agents/>
that still answers, and removes the links to agents that do not.

=item * Every non-interactive bash under such a shell makes the same test before
it runs its command, and picks again in the same way.  The interactive shell
names F</etc/sshagentshare.bash> in C<BASH_ENV>, unless the user set one, and
bash reads that file before a C<bash -c> or a script.  This shell repairs the
link only, and never points it at an agent of its own.

=item * When a login shell of sshd exits, F</etc/bash.bash_logout> removes the
link to its agent, and moves F<~/.ssh/agent.sock> away from it.  A tmux pane
does not do this, because the login still holds that agent.

=back

The logout hook is the fast path.  Bash does not read F<bash.bash_logout> when
a hangup or a kill ends the shell, and that is how a login usually ends when
its client machine shuts down.  The prompt runs only where a shell waits for
input.  A shell with a program in its foreground shows no prompt, so a tool of
that program that runs C<bash -c> depends on C<BASH_ENV>.

A job of cron gets neither the prompt nor C<BASH_ENV>.  A cron table that sets
C<SSH_AUTH_SOCK> to F<~/.ssh/agent.sock> can also set
C<BASH_ENV=/etc/sshagentshare.bash> and C<SHELL=/bin/bash>.

A shell that already runs when the recipe installs picks up nothing.  A new
login does, and so does each new tmux pane.

=head2 FILES

=over 4

=item F</etc/sshagentshare.bash>

The functions, and the hook in C<PROMPT_COMMAND>.  In a non-interactive bash,
only the repair of the link.

=item F</etc/profile.d/sshagentshare.sh>

Sources the file above in an interactive login bash, and exports C<BASH_ENV>
for the shells under it.  tmux starts each pane as a login shell, so a pane
reads it too.  It runs before F<~/.bashrc>, so a dotfile that starts its own
agent when none answers finds the shared one first.

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
