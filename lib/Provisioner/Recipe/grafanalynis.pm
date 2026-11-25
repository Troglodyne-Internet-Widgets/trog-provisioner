package Provisioner::Recipe::grafanalynis;

#ABSTRACT: Draw the Lynis audits of the fleet from the collector's syslog stream.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::grafanalynis - the Lynis audits of the fleet, drawn.

=head1 SYNOPSIS

    logs.example.test:
        logcollector: ~
        grafana:
            admin_password: secret:grafana/logs.example.test/password
        grafanalynis: ~

C<grafana> is configured next to it for the reason that
L<Provisioner::Recipe::grafanasyslog> gives: this recipe does not choose an
administrator password.

=head1 DESCRIPTION

L<Provisioner::Recipe::lynis> audits each guest every day, and sends the result
to syslog with the appname C<lynis>.  L<Provisioner::Recipe::logshipper> sends
it to the collector, and L<Provisioner::Recipe::grafanasyslog> puts it in the
C<syslog> measurement.  This recipe draws it on a dashboard of its own, the
Lynis audits dashboard:

=over 4

=item * a table with one row for each guest: the newest hardening index, the
number of warnings and suggestions, the time of the report, and the hours since
it.  A guest whose report is older than C<stale_after_hours> has a red cell,
because its audit has stopped or fails.

=item * a table of the current warnings, and one of the current suggestions:
guest, test and text.

=item * the hardening index of each guest over time.

=back

This recipe requires C<grafanasyslog>, and not C<lynis>.  The audits are of the
guests that ship their logs here, so the collector does not need to run Lynis
itself.

=head2 The numbers come out of the message in telegraf

The summary is one message, C<hardening_index=67 warnings=3 suggestions=48>,
in the string field C<message>.  InfluxDB here is 1.x and speaks InfluxQL (see
L<Provisioner::Recipe::grafana/InfluxDB 1.x, and why that is not an accident>).
InfluxQL can match a string against a regex in a C<WHERE>, but it has no
function that returns a part of a string.  So no query can read the numbers.

A Starlark processor of telegraf reads them when the message arrives, as
L<Provisioner::Recipe::grafanaossec> does for the alerts of OSSEC.  It adds
these to each point with the appname C<lynis>, and changes nothing else:

=over 4

=item * the summary: the integer fields C<lynis_hardening_index>,
C<lynis_warnings> and C<lynis_suggestions>.  It also adds C<lynis_reported>,
the time of the message in seconds, because InfluxQL cannot do arithmetic on
the time of a point, and the dashboard subtracts it from the present time to
get the age of the report.  The time is that of the message, from the
C<timestamp> field of the syslog input, and not the time of the point, which is
when the message arrived.  A shipper holds the messages of its guest while the
collector is down, and a held report is as old as its message says.

=item * a warning or a suggestion: the tags C<lynis_finding> (C<warning> or
C<suggestion>) and C<lynis_test> (such as C<KRNL-5830>), and the field
C<lynis_text>.

=back

F<scripts/lynis_audit> sends the same messages as before.  A point stored
before this recipe was on the collector has none of these fields, so the
dashboard starts with the first audit after the build.

=head2 The current findings, and their limit

InfluxQL cannot select the points of the newest run of each guest, because
that needs the time of one query in the C<WHERE> of another.  So the tables of
findings show the findings of the last C<stale_after_hours>, one row for each
guest and test.  The audit runs once a day, so that is the newest run.  When
somebody runs the audit again by hand, a finding that the second run no longer
reports stays in the table until it is older than C<stale_after_hours>.  The
findings of a guest whose report is stale leave the tables.  The first table
shows that guest in red.

=head2 The dashboard names its datasource

As in L<Provisioner::Recipe::grafanasyslog>, the dashboard names its
datasource, and C<datasource> must be the name that
L<Provisioner::Recipe::grafana> gave it.  F<t/recipes.t> checks that the two
defaults agree.

=head1 METHODS

=head2 $bool = $recipe->is_multi_tenant()

False.  There is one processor in one telegraf, and one dashboard.

Returns 0.

    my $shared = $recipe->is_multi_tenant();

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

=over 4

=item * C<datasource>: the grafana datasource that the dashboard reads.

=item * C<stale_after_hours>: the age at which the report of a guest is stale.
The audit runs every day, so it is at least 25.

=back

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %args = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            datasource => {
                type        => 'string',
                default     => 'InfluxDB',
                description => 'The grafana datasource the dashboard reads.  Must match the grafana recipe datasource_name, which t/recipes.t checks.',
            },
            stale_after_hours => {
                type        => 'integer',
                default     => 26,
                minimum     => 25,
                description => 'Hours after which the dashboard shows the Lynis report of a guest as stale, and the age of the newest findings that it shows.  The audit runs daily, so less than 25 marks a working guest as stale for part of each day.',
            },
        },
    );
}

=head2 %required = $recipe->required_recipes(%opts)

C<grafanasyslog>, which installs telegraf and grafana and puts the stream in
the measurement that this recipe reads.

Returns the pair C<grafanasyslog> and a code reference that returns no options.

    my %required = $recipe->required_recipes();

=cut

sub required_recipes {
    return ( grafanasyslog => sub { () } );
}

=head2 %files = $recipe->template_files()

The telegraf fragment, the Starlark processor and the dashboard.

Returns a list of pairs, from each template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    return (
        'grafanalynis.telegraf.tt'  => 'grafanalynis_telegraf.conf',
        'grafanalynis.findings.tt'  => 'grafanalynis_findings.star',
        'grafanalynis.dashboard.tt' => 'grafanalynis_dashboard.json',
    );
}

=head2 @tests = $recipe->tests()

Returns the template for the test that runs on the guest:
F<grafanalynis.tt>.

    my @tests = $recipe->tests();

=cut

sub tests { return ('grafanalynis.tt') }

1;
