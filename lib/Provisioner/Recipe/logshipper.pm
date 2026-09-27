package Provisioner::Recipe::logshipper;

#ABSTRACT: Forward this guest's syslog to somewhere that keeps it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Utils();

=head1 NAME

Provisioner::Recipe::logshipper - send this guest's logs to a named destination.

=head1 SYNOPSIS

    _base:
        logshipper:
            host: logs.example.test

Or, for one guest that is different:

    dmz.example.test:
        logshipper:
            host: syslog.vendor.example
            selector: '*.warn;auth,authpriv.*'

=head1 DESCRIPTION

Configures rsyslog to forward the log stream of this guest to C<host>.
L<Provisioner::Recipe::logcollector> configures the far end, separately.  A
guest names a destination, and the destination never learns who its senders
are.

=head2 Naming it is the opt-in

C<host> is required and has no default.  There is no "off" setting.  A guest
that does not run this recipe ships nowhere and keeps its own logs, and that is
what off means.  A guest that names the recipe but does not say where to send
is a mistake.  The build fails on it, and does not make a guest that quietly
forwards nothing.

=head2 How C<host> is resolved

If the ip pool has an address for the name, the recipe uses that address.  It
uses any other value as written.  So a destination inside this installation does
not need DNS to receive the logs that tell you DNS is down.  You name an
external syslog service the usual way.

The recipe refuses a URL, because rsyslog takes a host there.  It reads the
transport and the port from C<protocol> and C<port>.

This is deliberately weaker than C<mirror> in L<Provisioner::DistroRecipe>,
which B<dies> on a name that the pool does not know.  The mirror must die,
because cloud-init uses it before the guest has a resolver.  This recipe runs
from the makefile, and by then the resolvers of the guest are configured.

A guest configured to ship to B<itself> ships nowhere, and prints a message that
says so.  The usual way to turn on logging for a fleet is one C<_base> block, and
that block also covers the collector.  A collector that forwards to its own
listener makes a loop.

=head2 It needs the firewall opened outwards, not inwards

A guest that this tool builds denies outgoing traffic by default.
C<scripts/setup-ufw-rules> issues an C<allow out> for every profile in
C</etc/ufw/applications.d>.  So a sender needs a profile that names the
destination port, although it listens on nothing.  Without one, rsyslog cannot
open the connection at all.  From the guest, that failure looks the same as
having nothing to send.

The profile also opens the port inbound, because that script does so for every
profile it finds.  Nothing listens on the port here, so inbound traffic reaches
a closed port.

=head2 The failure that the guest test makes visible

From the guest, a misconfigured destination and a working one look the same.
Because of C<action.resumeRetryCount> and a memory queue, rsyslog retries a dead
destination, suspends the action and discards the messages.  It logs nothing
about any of it.

So the guest test opens a TCP connection to C<host:port> and fails if nothing
answers.  That one assertion is the only one that catches a dead destination.

=cut

=head1 METHODS

=head2 %args = $recipe->args()

=over 4

=item * C<host> -- B<required>, no default.  See L</Naming it is the opt-in>.

=item * C<selector> -- which facilities and severities to forward, in the usual
notation of rsyslog.  Defaults to C<*.*>, which is everything.  It is a setting
because somebody must decide the volume and the contents of the whole log stream
of a guest.

=item * C<retry> and C<queue_size> -- how hard rsyslog tries a destination that
does not answer, and how much it holds in memory in the meantime.  They are
named here because these two numbers make a total failure invisible.  See
L</The failure that the guest test makes visible>.

=back

=cut

=head2 $bool = $recipe->is_multi_tenant()

False.  The machine has one rsyslog and one
F</etc/rsyslog.d/10-logshipper.conf> that says where it forwards.  The
destination, the selector and the port are arguments of one domain.  If two
domains want different collectors, the first domain built decides where all
logs go, including the logs of the second domain.

=cut

sub is_multi_tenant { return 0 }

sub args {
    return (
        type       => 'object',
        required   => ['host'],
        properties => {
            host => {
                type        => 'string',
                description => 'Where to send this guest logs.  Required: a guest that does not run this recipe already ships nowhere, so there is no off.  A name the ip pool knows is resolved to its address; anything else is used as written.  A host, not a URL.',
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

        # The ufw profile for outbound traffic.  See L</It needs the firewall
        # opened outwards, not inwards>.
        'logshipper.ufw.conf.tt' => 'logshipper_ufw.conf',
    );
}

=head2 @tests = $recipe->tests()

=cut

sub tests { return ('logshipper.tt') }

=head2 %opts = $recipe->enrich(%opts)

Returns C<%opts> with C<target> added, as the C<target> method returns it.  The
templates test C<target> and not C<host>, because C<target> is empty for a guest
that is its own destination.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{target} = $self->target(%opts);
    return %opts;
}

=head2 $target = $recipe->target(%opts)

Takes C<host>, C<domain> and C<ipmap> (domain name to address).  Returns the
address or name to give rsyslog, as L</How C<host> is resolved> says.  For a guest
that is its own destination, prints a message and returns empty.  Does not die.

=cut

sub target {
    my ( $self, %opts ) = @_;

    my $domain = $opts{domain} // q{};
    my ( $kind, $value ) = Provisioner::Utils::fleet_address( $opts{host}, domain => $domain, ipmap => $opts{ipmap} );

    if ( $kind eq 'self' ) {
        print "$domain is the log destination, so it keeps its logs rather than forwarding them to itself.\n";
        return q{};
    }

    # The omfwd action of rsyslog takes a host name or an address in target=,
    # and has protocol= and port= for the rest of what a URL says.
    die <<"NOPE" if $kind eq 'url';
'$opts{host}' is a URL, and $domain ships its logs to a host.  rsyslog takes the
host alone, and the transport and port from their own settings:

    logshipper:
        host: logs.example.test
        protocol: tcp
        port: 514
NOPE

    return $value;
}

1;
