package Provisioner::Recipe::logshipper;

#ABSTRACT: Forward this guest's syslog to somewhere that keeps it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use Provisioner::Utils();

=head1 NAME

Provisioner::Recipe::logshipper - send this guest's logs to a named destination.

=head1 SYNOPSIS

    _base:
        logshipper:
            host: logs.example.com

or, for one guest that differs:

    dmz.example.com:
        logshipper:
            host: syslog.vendor.example
            selector: '*.warn;auth,authpriv.*'

=head1 DESCRIPTION

Configures rsyslog to forward this guest's log stream to C<host>.  What happens
at the far end is L<Provisioner::Recipe::logcollector>'s problem, and is
configured separately -- a guest names a destination, and the destination never
learns who its senders are.

=head2 Naming it is the opt-in

C<host> is required and has no default.  There is no "off" setting because a
guest that does not run this recipe already ships nowhere and keeps its own
logs, which is what off means; a guest that names the recipe and does not say
where to send is a mistake worth failing the build over rather than a guest that
quietly forwards nothing.

=head2 Where the destination is not the hypervisor any more

Every guest this tool built used to be told, unconditionally, that its logs went
to its hypervisor's NAT address -- a claim manufactured out of C<virbr_ip> and
compiled in, whether or not anything there was listening.  Nothing said so, and
nothing could tell: C<action.resumeRetryCount> and a memory queue mean rsyslog
retries a dead destination, suspends the action, and drops the messages without
a word.  See L</The failure this is shaped to make visible>.

=head2 How C<host> is resolved

A name the ip pool has an address for is resolved to that address; anything else
is used as written.  So a destination inside this installation does not depend
on DNS being up to receive the logs that would tell you DNS is down, and an
external syslog service is named the way you would expect to name one.

That is deliberately weaker than L<Provisioner::DistroRecipe>'s C<mirror>, which
B<dies> on a name the pool does not know.  It has to: a mirror is used by
cloud-init, before the guest has a resolver at all.  This recipe runs from the
makefile, by which time the guest's resolvers are configured.

A guest configured to ship to B<itself> ships nowhere, and says so.  The natural
way to turn logging on for a fleet is one C<_base> block, which necessarily
covers the collector as well -- and a collector forwarding to its own listener
is a loop.

=head2 It needs the firewall opened outwards, not inwards

A guest this tool builds defaults to C<deny (outgoing)>, and
C<scripts/setup-ufw-rules> issues an C<allow out> for every profile in
C</etc/ufw/applications.d>.  So a sender needs a profile naming the destination
port even though it listens on nothing -- without one rsyslog cannot open the
connection at all, and being unable to is indistinguishable from having nothing
to say.

That profile opens the port inbound too, which is what that script does for
every profile it finds.  Nothing is listening on it here, so the inbound half
reaches a closed port.

=head2 The failure this is shaped to make visible

A misconfigured destination and a working one look identical from the guest:
rsyslog queues, retries, suspends and discards, and logs nothing about any of
it.  That is the whole reason the previous arrangement went years without
anybody noticing it had never once worked.

So the guest test opens a TCP connection to C<host:port> and fails if nothing
answers.  It is the one assertion that would have caught it, and it is worth
more than everything else in that file put together.

=cut

=head1 METHODS

=head2 %args = $recipe->args()

=over 4

=item * C<host> -- B<required>, no default.  See L</Naming it is the opt-in>.

=item * C<selector> -- which facilities and severities to forward, in rsyslog's
usual notation.  Defaults to C<*.*>, everything, which is what a guest has always
been configured to send.  It is a setting because the volume and the contents of
a guest's whole log stream ought to be somebody's decision rather than a
constant nobody chose.

=item * C<retry> and C<queue_size> -- how hard rsyslog tries a destination that
is not answering, and how much it holds in memory meanwhile.  Carried over from
when they were constants, and named here so that the two numbers responsible for
making a total failure invisible are at least visible.

=back

=cut

sub args {
    ## no critic (ValuesAndExpressions::ProhibitMagicNumbers)
    return (
        type       => 'object',
        required   => ['host'],
        properties => {
            host => {
                type        => 'string',
                description => 'Where to send this guest logs.  Required: a guest that does not run this recipe already ships nowhere, so there is no off.  A name the ip pool knows is resolved to its address; anything else is used as written.',
            },
            port => {
                type        => 'integer',
                default     => 514,
                minimum     => 1,
                maximum     => 65535,
                description => 'Port the destination listens on.  Must match the logcollector port at the other end.',
            },
            protocol => {
                type        => 'string',
                default     => 'tcp',
                enum        => [qw{tcp udp}],
                description => 'Transport.  tcp, because a dropped log line is not worth the datagram it saved -- and because a udp destination cannot be checked for, so the guest test can say far less about it.',
            },
            selector => {
                type        => 'string',
                default     => '*.*',
                description => 'Which facilities and severities to forward, in rsyslog notation.  Everything, by default.',
            },
            retry => {
                type        => 'integer',
                default     => 100,
                minimum     => -1,
                description => 'How many times rsyslog retries a destination that is refusing before suspending the action.  -1 is forever.',
            },
            queue_size => {
                type        => 'integer',
                default     => 10000,
                minimum     => 1,
                description => 'Messages held in memory while the destination is unreachable.  Not disk-assisted, so this much is what a reboot can lose.',
            },
        },
    );
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return (
        'logshipper.conf.tt' => 'logshipper.conf',

        # For the outbound half.  See the template, and L</It needs the firewall
        # opened outwards, not inwards>.
        'logshipper.ufw.conf.tt' => 'logshipper_ufw.conf',
    );
}

=head2 @tests = $recipe->tests()

=cut

sub tests { return ('logshipper.tt') }

=head2 %opts = $recipe->enrich(%opts)

Resolves C<host> into the address or name rsyslog is given, per L</How C<host> is
resolved>.  Empty when this guest is its own destination, which is what the
templates check rather than checking C<host>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{target} = $self->target(%opts);
    return %opts;
}

=head2 $target = $recipe->target(%opts)

The address or name to hand rsyslog, or empty for a guest that would be shipping
to itself.

=cut

sub target {
    my ( $self, %opts ) = @_;

    my $domain = $opts{domain} // q{};
    my ( $kind, $value ) = Provisioner::Utils::fleet_address( $opts{host}, domain => $domain, ipmap => $opts{ipmap} );

    if ( $kind eq 'self' ) {
        print "$domain is the log destination, so it keeps its logs rather than forwarding them to itself.\n";
        return q{};
    }

    # A name this installation assigns an address to is pinned to that address,
    # so the logs that would tell you DNS is broken do not need DNS to arrive.
    # Anything else is a destination we do not run, and is named as written.
    return $value;
}

1;
