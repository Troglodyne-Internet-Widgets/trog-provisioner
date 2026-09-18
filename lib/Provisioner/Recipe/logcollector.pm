package Provisioner::Recipe::logcollector;

#ABSTRACT: Receive the fleet's logs, one file per sender, and rotate them.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util qw{uniq};

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

This recipe opens a syslog listener.  It writes the messages that arrive to one
file for each sending host, and it rotates those files.  The sending half is
L<Provisioner::Recipe::logshipper>, which you configure separately.

=head2 No sender depends on this

No recipe puts C<logcollector> in its C<required_recipes> to ship logs to it.
The relation goes in one direction, through configuration.  A guest names a
destination, and the destination does not know its senders.

This is necessary, not only tidy.  See
L</It cannot know its senders, so it does not try>.

A consumer on the collector itself is a different relation, and this recipe
serves it.  See L</Forwarding a copy, for something on this guest>.

=head2 Forwarding a copy, for something on this guest

C<forward> adds one C<omfwd> action for each destination to the collector
ruleset, above the C<stop>.  The position is necessary.  C<stop> ends the
processing of the message, so an action below it never runs.

The copy goes out as RFC5424 with octet-counted framing.  The telegraf
C<[[inputs.syslog]]> input parses that format, and it rejects RFC3164, which
rsyslog sends by default.

L<Provisioner::Recipe::grafanasyslog> is the reason for this feature.  It
requires this recipe and asks for the stream on a loopback port.  So the logs of
the fleet reach a dashboard without a second listener on the network.

This recipe opens no firewall port for a destination.  A consumer on this guest
listens on loopback.  A consumer on a different guest is a second collector, and
this feature is not for that.

=head2 It cannot know its senders, so it does not try

A collector is built like any other guest, from its own configuration.  Most of
the guests that ship to it do not exist yet at that time.  So it cannot get a
list of them, and it does not route on one:

    template(name="..." type="string" string="<log_dir>/%HOSTNAME:::secpath-replace%.log")

rsyslog evaluates this one template for each message.  A new guest starts to log
here when it is built, and nothing else has to change.

C<secpath-replace> is necessary.  C<%HOSTNAME%> is the name that the sender put
in the message.  Without C<secpath-replace>, a sender can call itself
C<../../etc/cron.d/anything> and choose where this guest writes.

=head2 Remote logs do not land in this guest's own syslog

The listener has its own ruleset, and the per-host action in it ends with
C<stop>.  So each message from the fleet is written once, to the file for its
sender.  It never gets to the default rules, and the C</var/log/syslog> of this
guest contains only its own messages.  Because the C<stop> is in that ruleset
only, the local logs of this guest are not discarded.

For the same reason, a plain C<logger> on this guest does not write to
C<log_dir>, because local messages do not enter that ruleset.  A message sent to
the port does enter it.  The guest test sends one to test the full path.

=head2 Rotation reopens the files

The logrotate configuration ends with a C<postrotate> that signals rsyslog.  This
makes rsyslog reopen the files that logrotate moved.

=head2 It wants a guest of its own

This is not a requirement, but know it.  The collector listens on a privileged
port for the full fleet.  Its data grows without limit, in proportion to how much
the other guests log.  Only C<retain> and C<rotate> limit the size, and only
C<allowed_senders> limits who can send.

=cut

=head1 METHODS

=head2 $bool = $recipe->is_multi_tenant()

False.  The machine has one listener: one port, one ruleset, and one
F</etc/rsyslog.d/09-logcollector.conf>.  A second domain does not add a second
collector.  It rewrites the collector that the fleet already ships to.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

Returns the schema.  C<bin/recipes> shows each field, its default and its
description.

C<log_dir> is outside C<install_dir> on purpose.  On each provision, the C<data>
target runs C<chown> and C<chmod> recursively on C<< install_dir/<domain> >>,
and this directory only grows.

=cut

sub args {
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
            forward => {
                type => 'array',

                # Validated here, not in enrich, so that the error names the
                # bad destination and its field.
                items       => { type => 'string', pattern => '^[^:\s]+:[0-9]+$' },
                default     => [],
                description => 'host:port destinations each received message is copied to, above the ruleset stop.  For a consumer on this guest, such as the telegraf grafanasyslog configures.  A bracketed IPv6 literal is refused rather than supported: the consumers this exists for are on loopback.',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Returns C<%opts> with each repeated C<forward> destination removed.

More than one party can ask for the same destination.  For example, an operator
names it, and L<Provisioner::Recipe::grafanasyslog> asks for it as a dependent.
C<reconcile> settles only scalar fields, and L<Hash::Merge> joins the two arrays.
Without this method, the ruleset gets two identical C<omfwd> actions and sends
each message to that port twice.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{forward} = [ uniq @{ $opts{forward} } ] if ref $opts{forward} eq 'ARRAY';

    return %opts;
}

=head2 %limits = $recipe->rate_limits(%opts)

Returns a limit of 256 on the configured port and protocol, not on 514.  So a
collector on a different port gets the limit where it listens.  A busy fleet
keeps its connections open and does not open one for each message, so this
limit is generous.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;

    # Defaulted here and in args, because required_recipes asks for these
    # limits before validation.
    my $port = $opts{port}     // 514;
    my $prot = $opts{protocol} // 'tcp';

    return ( "$port/udp" => 256 )                     if $prot eq 'udp';
    return ( $port       => 256, "$port/udp" => 256 ) if $prot eq 'both';
    return ( $port       => 256 );
}

=head2 %files = $recipe->template_files()

Returns the rsyslog configuration, the logrotate configuration and the ufw
profile, each mapped to the name of the file that it becomes.

=cut

sub template_files {
    return (
        'logcollector.conf.tt'      => 'logcollector.conf',
        'logcollector.logrotate.tt' => 'logcollector.logrotate',

        # Rendered here, not by ufw, because ufw gets only rate_limits and
        # does not know the port that this recipe configured.
        'logcollector.ufw.conf.tt' => 'logcollector_ufw.conf',
    );
}

=head2 @tests = $recipe->tests()

Returns the guest test F<logcollector.tt>.

=cut

sub tests { return ('logcollector.tt') }

1;
