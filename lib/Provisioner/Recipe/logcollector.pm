package Provisioner::Recipe::logcollector;

#ABSTRACT: Receive the fleet's logs, one file per sender, and rotate them.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::logcollector - a guest that keeps everybody else's logs.

=head1 SYNOPSIS

    logs.example.test:
        logcollector:
            retain: 52

and then point the fleet at it:

    _base:
        logshipper:
            host: logs.example.test

=head1 DESCRIPTION

Opens a syslog listener, writes what arrives to one file per sending host, and
rotates them.  The other half is L<Provisioner::Recipe::logshipper>, which is
configured separately.

=head2 Nothing depends on this

No recipe puts C<logcollector> in its C<required_recipes>, and none should.  The
relationship runs one way and through configuration: a guest names a destination,
and the destination does not know who its senders are.

That is not only tidiness -- it is what makes the arrangement work at all.  See
L</It cannot know its senders, so it does not try>.

=head2 It cannot know its senders, so it does not try

A collector is built like any other guest, from its own configuration, before
most of the guests that will ship to it exist.  So it cannot be handed a list of
them, and it does not route on one:

    template(name="..." type="string" string="<log_dir>/%HOSTNAME:::secpath-replace%.log")

One template, evaluated per message.  A new guest starts logging here the moment
it is built, and nothing has to be added anywhere for that to happen.

This replaces an arrangement where C<bin/provision> wrote one drop-in per domain
onto the hypervisor and restarted rsyslog there on every build, and C<bin/destroy>
took it back off again.  Two bugs go with it: a destroyed guest's log file no
longer needs cleaning up, and the rotation stops covering guests that no longer
exist.

C<secpath-replace> is load-bearing rather than decoration.  C<%HOSTNAME%> is
whatever the sender put in the message, so without it a sender could name itself
C<../../etc/cron.d/anything> and choose where this guest writes.

=head2 Remote logs do not land in this guest's own syslog

The listener has a ruleset of its own, and the per-host action ends with C<stop>
inside it.  So the fleet's messages are written once, to the file named for their
sender, and never reach the default rules -- this guest's C</var/log/syslog> stays
its own.  Scoping the C<stop> to that ruleset is what keeps it from swallowing
this guest's local logging too.

It is also why a plain C<logger> on this guest does not appear under C<log_dir>:
local messages never enter that ruleset.  Sending one over the port does, which
is what the guest test does to prove the path end to end.

=head2 Rotation actually reopens the files

The logrotate configuration this installs ends with a C<postrotate> that signals
rsyslog.  The one it replaces had an empty C<postrotate>/C<endscript> pair, so
nothing ever told rsyslog to reopen what had been rotated out from under it.

=head2 It wants a guest of its own

Not fatal, but worth knowing: it listens on a privileged port for the whole
fleet, and it grows without bound in proportion to how much everything else
says.  C<retain> and C<rotate> are the only things bounding that, and
C<allowed_senders> is the only thing bounding who can contribute to it.

=cut

=head1 METHODS

=head2 %args = $recipe->args()

=over 4

=item * C<log_dir> -- where the per-sender files go.  Outside C<install_dir> on
purpose: the C<data> target chowns and chmods C<< install_dir/<domain> >>
recursively on every provision, and this is a directory that only ever grows.

=item * C<allowed_senders> -- CIDRs permitted to log here.  Empty means rsyslog
does not filter by source and whatever reaches the port is accepted, which is
then only as narrow as the firewall.

=back

=cut

sub args {
    ## no critic (ValuesAndExpressions::ProhibitMagicNumbers)
    return (
        type       => 'object',
        properties => {
            port => {
                type        => 'integer',
                default     => 514,
                minimum     => 1,
                maximum     => 65535,
                description => 'Port to listen on.  Must match the logshipper port at the other end.',
            },
            protocol => {
                type        => 'string',
                default     => 'tcp',
                enum        => [qw{tcp udp both}],
                description => 'Transport to accept.  tcp by default, matching what logshipper sends.',
            },
            log_dir => {
                type        => 'string',
                default     => '/var/log/hosts',
                description => 'Where the per-sender log files are written.  Outside install_dir on purpose: the data target walks install_dir recursively on every provision.',
            },
            retain => {
                type        => 'integer',
                default     => 12,
                minimum     => 1,
                description => 'How many rotations to keep.  Twelve weekly rotations is a quarter, which is what this has always kept.',
            },
            rotate => {
                type        => 'string',
                default     => 'weekly',
                enum        => [qw{daily weekly monthly}],
                description => 'How often to rotate.',
            },
            compress => {
                type        => 'boolean',
                default     => 1,
                description => 'Compress rotated files.  Log text compresses to almost nothing, so this is on.',
            },
            allowed_senders => {
                type        => 'array',
                items       => { type => 'string' },
                default     => [],
                description => 'CIDRs allowed to log here, as rsyslog AllowedSender entries.  Empty accepts whatever the firewall let through.',
            },
        },
    );
}

=head2 %limits = $recipe->rate_limits(%opts)

On the configured port rather than on 514, so a collector that was moved has the
limit applied where it is actually listening.  A busy fleet holds connections
open rather than opening one per message, so this is generous for what it needs
to be.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;

    ## no critic (ValuesAndExpressions::ProhibitMagicNumbers)
    # Defaulted here as well as in args, because required_recipes is asked
    # before anything has been validated.
    my $port = $opts{port}     // 514;
    my $prot = $opts{protocol} // 'tcp';

    return ( "$port/udp" => 256 )                     if $prot eq 'udp';
    return ( $port       => 256, "$port/udp" => 256 ) if $prot eq 'both';
    return ( $port       => 256 );
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return (
        'logcollector.conf.tt'      => 'logcollector.conf',
        'logcollector.logrotate.tt' => 'logcollector.logrotate',

        # The ufw profile for the port this guest configured, rendered here
        # rather than by ufw, which is handed rate_limits and nothing else and
        # so cannot name a port that was configured over here.
        'logcollector.ufw.conf.tt' => 'logcollector_ufw.conf',
    );
}

=head2 @tests = $recipe->tests()

=cut

sub tests { return ('logcollector.tt') }

1;
