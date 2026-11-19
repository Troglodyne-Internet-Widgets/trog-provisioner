package Provisioner::Recipe::ossec;

#ABSTRACT: Run an OSSEC manager on the collector, over the stream of the fleet's logs, and draw its alerts.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::ossec - intrusion detection over the logs that the collector already receives.

=head1 SYNOPSIS

    logs.example.test:
        logcollector: ~
        grafana:
            admin_password: secret:grafana/logs.example.test/password
        grafanasyslog: ~
        ossec: ~

C<grafana> is configured next to it for the reason that
L<Provisioner::Recipe::grafanasyslog> gives: this recipe does not choose an
administrator password.

=head1 DESCRIPTION

OSSEC is a host intrusion detection system.  Its manager decodes log lines,
matches them against rules, and raises an alert with a level from 0 to 15 for
each match.  This recipe runs the manager on the collector and gives it every
message of the fleet, with no agent on any guest.  The alerts go to the
dashboards of L<Provisioner::Recipe::grafanasyslog>.

=head2 The path of a message

=over 4

=item 1. L<Provisioner::Recipe::logcollector> receives the message from a guest,
and copies it to C<127.0.0.1:port> as a line of text.  This recipe asks for that
copy through C<forward_text>, because the decoders of OSSEC find nothing in
RFC5424, the format of the other C<forward>.

=item 2. The syslog listener of the manager reads it.  The manager keeps the
name of the guest from the line, so an alert names the guest and not the
collector.

=item 3. The manager sends each alert as JSON in a syslog message from the
program C<ossec>, over UDP to C<127.0.0.1:alerts_port>.

=item 4. A second syslog input of telegraf reads it, into the same
measurement as the rest of the stream.  So the syslog dashboard shows the
alerts under the appname C<ossec>.  A Starlark processor decodes the JSON,
because InfluxQL cannot look into it, and makes the level, the rule, the rule
groups and the guest into tags.  The OSSEC dashboard groups by those tags.

=back

Every hop is on loopback, so nothing goes on the wire and no firewall profile is
necessary.

The alerts do not go back through rsyslog.  If they did, the collector copies
them to the manager like any other message, and the manager can raise an alert
on its own alert.

=head2 What is not on yet

Active response is off.  fail2ban stays, and the manager blocks nothing.

The manager sends no mail.  The cron jobs of L<Provisioner::Recipe::cron> still
mail what they find.  Each one goes when a rule here covers it.

syscheck and rootcheck are off on the manager.  They belong to the agents.

=head2 The package comes from Atomicorp

OSSEC is not in the Ubuntu archive.  Atomicorp, who maintain OSSEC, publish
C<ossec-hids-server> in an archive of their own, and
L<Provisioner::Recipe::Ubuntu::ossec> takes the package from there.  The archive
can be a release behind the source.

=head2 The rules are listed in order

F<ossec.conf> includes each rule file of the package by name, in the order of
the configuration that the package installs.  A rule refers to rules in the
files before it, so the files cannot load in the order of a directory.  If a new
package drops a file in the list, the manager does not start, and the guest test
fails.

=cut

=head1 METHODS

=head2 $bool = $recipe->is_multi_tenant()

False.  There is one manager on the machine, and one collector that feeds it.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

=over 4

=item * C<port>: the loopback TCP port where the manager reads the copy of the
stream.  It is also the port that the collector sends to.

=item * C<alerts_port>: the loopback UDP port where telegraf reads the alerts.

=item * C<datasource>: the grafana datasource that the dashboard reads.  It
must be the name that L<Provisioner::Recipe::grafana> gave it, which
F<t/recipes.t> checks.

=back

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            port => {
                type        => 'integer',
                default     => 10514,
                minimum     => 1024,
                maximum     => 65535,
                description => 'Loopback TCP port the OSSEC manager reads the copy of the collector stream on, and the port logcollector is told to copy to.',
            },
            alerts_port => {
                type        => 'integer',
                default     => 10516,
                minimum     => 1024,
                maximum     => 65535,
                description => 'Loopback UDP port the manager sends its alerts to, and telegraf reads them on.',
            },
            datasource => {
                type        => 'string',
                default     => 'InfluxDB',
                description => 'The grafana datasource the dashboard reads.  Must match the grafana recipe datasource_name, which t/recipes.t checks.',
            },
        },
    );
}

=head2 %required = $recipe->required_recipes(%opts)

C<logcollector>, with the copy as text that the manager reads, and
C<grafanasyslog>, which installs telegraf and grafana and puts the stream in the
measurement that the alerts join.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because this runs before validation.
    my $port = $opts{port} // 10514;

    return (
        logcollector  => sub { ( forward_text => ["127.0.0.1:$port"] ) },
        grafanasyslog => sub { () },
    );
}

=head2 @claims = $recipe->listens(%opts)

The listener of the manager on C<port>, and the input of telegraf on
C<alerts_port>, both on 127.0.0.1.

=cut

sub listens {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, as required_recipes does.
    return ( '127.0.0.1:' . ( $opts{port} // 10514 ), '127.0.0.1:' . ( $opts{alerts_port} // 10516 ) . '/udp' );
}

=head2 @hosts = $recipe->fetch_hosts()

The archive of Atomicorp.

=cut

sub fetch_hosts {
    return (qw{updates.atomicorp.com});
}

=head2 @classes = $recipe->cache_classes()

The archive, as an apt repository.

=cut

sub cache_classes {
    my ($class) = @_;

    return map { $class->apt_repo_classes($_) } $class->fetch_hosts();
}

=head2 %files = $recipe->template_files()

The configuration of the manager, the telegraf fragment, the Starlark processor
and the dashboard.

=cut

sub template_files {
    return (
        'ossec.conf.tt'      => 'ossec.conf',
        'ossec.telegraf.tt'  => 'ossec_telegraf.conf',
        'ossec.alerts.tt'    => 'ossec_alerts.star',
        'ossec.dashboard.tt' => 'ossec_dashboard.json',
    );
}

=head2 @tests = $recipe->tests()

Returns the template for the test that runs on the guest.

=cut

sub tests { return ('ossec.tt') }

1;
