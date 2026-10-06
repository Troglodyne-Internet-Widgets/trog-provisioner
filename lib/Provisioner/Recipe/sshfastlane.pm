package Provisioner::Recipe::sshfastlane;

#ABSTRACT: A second sshd for sources that logged in before, so a scan that fills MaxStartups does not lock out a known client.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::sshfastlane

=head2 SYNOPSIS

    somedomain:
        sshfastlane:

That is usually all.  See C<args> for what you can change.

=head2 DESCRIPTION

This recipe exists so that a scan does not lock out a legitimate client.

sshd drops new connections when too many connections have not finished their
login.  C<MaxStartups> sets that limit, and it is one count for all sources
together.  A scanner that opens connections and never finishes them fills the
count, and sshd then drops connections from everybody.  On a guest that gets
scanned all day, an rsync backup or an administrator fails to connect at
random.  C<PerSourceMaxStartups> limits one source, but it does not protect a
client from many sources.  C<PerSourcePenaltyExemptList> exempts a source from
penalties, but not from C<MaxStartups>.  A firewall allow rule does not help
either: it lets the packet reach sshd, and sshd still counts the connection.

So this recipe gives known clients their own sshd, with its own count:

=over 4

=item * A second sshd listens on C<port>.  Its configuration sets its own
C<MaxStartups> and then includes F</etc/ssh/sshd_config>, so it has the same
host keys, the same authentication policy and the same users as the main one.
sshd uses the first value that it reads for an option, so the values above the
include win.

=item * A PAM session hook adds the source address of each successful login to
the ipset C<ssh-fastlane>, with a timeout of C<trust_days>.  Each later login
from that address starts the timeout again.

=item * A nat rule redirects port 22 from an address in the set to C<port>.
The client still connects to port 22, and it does not need to know about the
fast lane.  A scanner that never logged in stays in the main queue.

=back

A source in the set only skips the queue.  It still has to authenticate.

=head2 What keeps the fast lane from locking people out itself

A redirect to an sshd that does not run refuses the connection.  That is a
lockout of exactly the clients that this recipe is for.  So the set is only
full while the fast lane sshd runs:

=over 4

=item * The unit is C<Type=notify>, so C<ExecStartPost> fills the set from
F</var/lib/ssh-fastlane/members> only after sshd listens.

=item * C<ExecStopPost> saves the set to that file and empties it.  systemd runs
it on every stop, also after a crash.  So when the fast lane is down, every
client goes to the main sshd, as if this recipe were not there.

=item * The PAM hook adds nobody while the fast lane is not active.

=back

The set survives a reboot through that file, with the time that each address
had left.  ipset cannot hold a timeout over 2147483 seconds, so C<trust_days>
is at most 24.

=head2 The firewall

ufw does not own these rules, because a ufw rule cannot match an ipset.
F</etc/ufw/after.init> calls C<ssh-fastlane firewall start> each time ufw
loads, and C<firewall stop> each time ufw unloads.  C<ufw reset> restores the
C<.rules> files and does not touch F<after.init>, so the rules survive the
reset in the C<ufw> target.  They also stay out of F<before.rules>, where
C<setup-port-forwards> and C<setup-masquerade> share the one C<*nat> table.
The script makes the set before the first rule that reads it.

=over 4

=item * In the nat table, the chain C<trog-fastlane> redirects tcp port 22 from
the set to C<port>.

=item * In the filter table, the chain C<trog-fastlane> drops a connection to
C<port> that the redirect did not send there.  Loopback is exempt, so a guest
test can reach the fast lane sshd directly.

=item * An application profile, C<ssh-fastlane>, lets the redirected connections
through ufw.  ufw checks it in C<ufw-user-input>, after the C<deny> rules that a
fail2ban ban inserts.  So a ban still applies to an address in the set.

=back

The rate limit that C<ufw> puts on port 22 does not count the fast lane.  The
filter table sees a redirected connection on C<port>, not on 22.

=head2 Limits

=over 4

=item * IPv4 only.  An IPv6 client logs in through the main sshd, as before.

=item * The fast lane sshd binds C<0.0.0.0:port>.  If F</etc/ssh/sshd_config>
names a C<ListenAddress> of its own, the fast lane binds that address too,
because sshd adds up C<ListenAddress> lines.  It then does not start.  The guest
test reports that.

=item * A trusted address that is a carrier NAT shares the fast lane with the
other users of that NAT.  They get a shorter queue, not access.

=item * The fast lane shortens the wait for a connection.  After the login, a
session on it is the same as a session on the main sshd.

=back

=cut

our $DEFAULT_PORT = 2222;

=head2 @claims = $recipe->listens(%opts)

The fast lane sshd on C<port>, on every IPv4 address.  A redirect rewrites the
destination to an address of the interface that the packet came in on, so the
sshd must listen on all of them.

=cut

sub listens {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because required_recipes calls this
    # before validation.
    return ( '0.0.0.0:' . ( $opts{port} // $DEFAULT_PORT ) );
}

sub args {
    return (
        type       => 'object',
        properties => {
            port => {
                type        => 'integer',
                minimum     => 1,
                maximum     => 65_535,
                not         => { enum => [22] },
                default     => $DEFAULT_PORT,
                description => 'The port that the fast lane sshd listens on.  Clients never connect to it directly: the firewall redirects port 22 there for a trusted source, and drops every other connection to it.',
            },
            max_startups => {
                type        => 'string',
                pattern     => q{\A\d+(?::\d+:\d+)?\z},
                default     => '100:30:200',
                description => 'The MaxStartups of the fast lane sshd, in the syntax of sshd_config.  Only sources that logged in before reach it, so this is far above the default of the main sshd.',
            },
            trust_days => {
                type        => 'integer',
                minimum     => 1,
                maximum     => 24,
                default     => 21,
                description => 'How long an address stays in the fast lane after its last successful login.  At most 24, because ipset cannot hold a longer timeout.',
            },
            ipqos => {
                type        => 'string',
                pattern     => q{\A[a-z\d]+(?:\ [a-z\d]+)?\z},
                default     => 'ef none',
                description => 'The IPQoS of the fast lane sshd: the DSCP mark for interactive sessions, then for bulk transfers, in the syntax of sshd_config.  The default marks a shell expedited and leaves an rsync unmarked.  OpenSSH 9.6 marks bulk transfers cs1, which a network that honors DSCP serves after everything else.  Most of the internet ignores the mark.',
            },
        },
    );
}

sub template_files {
    return (
        'sshfastlane.sh.tt'          => 'sshfastlane.sh',
        'sshfastlane.sshd_config.tt' => 'sshfastlane.sshd_config',
        'sshfastlane.service.tt'     => 'sshfastlane.service',
        'sshfastlane.after.init.tt'  => 'sshfastlane.after.init',
        'sshfastlane.ufw.conf.tt'    => 'sshfastlane_ufw.conf',
    );
}

sub tests {
    return qw{sshfastlane.tt};
}

1;
