package Provisioner::Recipe::grafanaossec;

#ABSTRACT: Put the alerts of the OSSEC manager into influxdb, and a dashboard over them.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::grafanaossec - the alerts of the OSSEC manager, drawn.

=head1 SYNOPSIS

    logs.example.test:
        logcollector: ~
        grafana:
            admin_password: secret:grafana/logs.example.test/password
        grafanaossec: ~

C<grafana> is configured next to it for the reason that
L<Provisioner::Recipe::grafanasyslog> gives: this recipe does not choose an
administrator password.

=head1 DESCRIPTION

L<Provisioner::Recipe::ossec> runs the manager on the collector, and keeps its
alerts on the guest.  This recipe draws them.  It requires C<ossec> and
C<grafanasyslog>, and the manager knows nothing about it.  It plugs in through
a fragment of F<ossec.conf.d>, as L<Provisioner::Recipe::ossec/What another
recipe can add> says.

=head2 The path of an alert

=over 4

=item 1. The fragment F<ossec.conf.d/60-grafanaossec> turns on the JSON output
of the manager, and sends each alert as JSON in a syslog message from the
program C<ossec>, over UDP to C<127.0.0.1:alerts_port>.  The build adds
C<ossec-csyslogd>, the daemon of that output, to the daemons that
C<ossec-control> starts.

=item 2. A second syslog input of telegraf reads it, into the same
measurement as the stream that L<Provisioner::Recipe::grafanasyslog> draws.  So
the syslog dashboard shows the alerts under the appname C<ossec>.

=item 3. A Starlark processor decodes the JSON, because InfluxQL cannot look
into it, and makes the level, the rule, the rule groups and the guest into
tags.  The OSSEC dashboard groups by those tags.

=back

Every hop is on loopback, so nothing goes on the wire.  The alerts do not go
back through rsyslog, for the reason that L<Provisioner::Recipe::ossec/What
another recipe can add> gives.

=head2 The dashboard names its datasource

As in L<Provisioner::Recipe::grafanasyslog>, the dashboard names its
datasource, and C<datasource> must be the name that
L<Provisioner::Recipe::grafana> gave it.  F<t/recipes.t> checks that the two
defaults agree.

=head1 METHODS

=head2 $recipe->is_multi_tenant()

False.  There is one manager on the machine, one output of its alerts, and one
dashboard.

Returns 0.

    my $shared = $recipe->is_multi_tenant();

=cut

sub is_multi_tenant { return 0 }

=head2 $recipe->args()

=over 4

=item * C<alerts_port>: the loopback UDP port where the manager sends its
alerts and telegraf reads them.

=item * C<datasource>: the grafana datasource that the dashboard reads.

=back

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %args = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            alerts_port => {
                type        => 'integer',
                default     => 10516,
                minimum     => 1024,
                maximum     => 65535,
                description => 'Loopback UDP port the OSSEC manager sends its alerts to, and telegraf reads them on.',
            },
            datasource => {
                type        => 'string',
                default     => 'InfluxDB',
                description => 'The grafana datasource the dashboard reads.  Must match the grafana recipe datasource_name, which t/recipes.t checks.',
            },
        },
    );
}

=head2 $recipe->required_recipes(%opts)

C<ossec>, whose alerts this draws, and C<grafanasyslog>, which installs
telegraf and grafana and puts the stream in the measurement that the alerts
join.

Returns the two names, each paired with a code reference that returns no
options.

    my %required = $recipe->required_recipes();

=cut

sub required_recipes {
    return (
        ossec         => sub { () },
        grafanasyslog => sub { () },
    );
}

=head2 $recipe->listens(%opts)

The input of telegraf on C<alerts_port>, on 127.0.0.1, over UDP.  The port is
10516 when C<%opts> does not name one.

Returns the one claim, such as C<127.0.0.1:10516/udp>, as a list.

    my @claims = $recipe->listens( alerts_port => 10516 );

=cut

sub listens {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because this runs before validation.
    return ( '127.0.0.1:' . ( $opts{alerts_port} // 10516 ) . '/udp' );
}

=head2 $recipe->template_files()

The fragment of F<ossec.conf>, the telegraf fragment, the Starlark processor and
the dashboard.

Returns a list of pairs, from each template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    return (
        'grafanaossec.conf.tt'      => 'grafanaossec.conf',
        'grafanaossec.telegraf.tt'  => 'grafanaossec_telegraf.conf',
        'grafanaossec.alerts.tt'    => 'grafanaossec_alerts.star',
        'grafanaossec.dashboard.tt' => 'grafanaossec_dashboard.json',
    );
}

=head2 $recipe->tests()

Returns the template for the test that runs on the guest:
F<grafanaossec.tt>.

    my @tests = $recipe->tests();

=cut

sub tests { return ('grafanaossec.tt') }

1;
