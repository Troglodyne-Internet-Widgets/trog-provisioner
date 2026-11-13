package Provisioner::Recipe::grafanaotel;

#ABSTRACT: Take OpenTelemetry from the fleet into influxdb, and keep its details for a short time.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Trog::Patterns();

# The name of an attribute of OpenTelemetry, which the processor writes into
# its starlark between double quotes.
my $ATTRIBUTE = qr/\A [[:alpha:]] [[:alnum:]_.]* \z/;

=head1 NAME

Provisioner::Recipe::grafanaotel - the telemetry of the fleet, drawn.

=head1 SYNOPSIS

    logs.example.test:
        grafana:
            admin_password: secret:grafana/logs.example.test/password
        grafanaotel:
            detail_retention: 48h

=head1 DESCRIPTION

Gives L<Provisioner::Recipe::grafana> a second stream to draw: OpenTelemetry,
as the OTLP exporters of a program send it over gRPC.  Claude Code is the
program that this recipe is for.  Its runs send metrics, such as cost and
tokens, and an event for each prompt, each request and each call of a tool.
This recipe adds a telegraf input that accepts them on C<port>, on every
address, and a processor, F<grafanaotel_details.star>, for the events.

The input stores an event as a point of C<logs>, with all of its attributes in
one field, C<attributes>, as a JSON string.  The resource attributes, such as
the C<clod.*> tags of App::Clod, are in it too.  InfluxQL cannot look into
JSON, so a dashboard could not group or filter by any of them.  The processor
decodes the field, and writes each attribute as a field of its own, or as a
tag when C<tag_fields> names it.  A tag is what InfluxQL groups by, so name
only attributes with few values, such as the name of a tool.

Like L<Provisioner::Recipe::grafanasyslog>, this recipe changes nothing in the
stack.  It writes its own telegraf fragment, and asks C<grafana> for one more
retention policy.

=head2 The details expire first

A program can send what its events are about along with them.  Claude Code
does so when C<OTEL_LOG_USER_PROMPTS> and C<OTEL_LOG_TOOL_DETAILS> are set:
the text of each prompt and response, the input of each tool call and its
full error.  That is what a person needs to find out why a run failed.  It is
also the part that can hold something that should not stay around, such as a
password that a command line carried.

InfluxDB 1.x expires data by retention policy, a point at a time, and cannot
remove one field of a point.  So the processor moves each attribute that
C<detail_fields> names into a point of its own, C<logs_detail>, with the same
tags and time, and leaves it out of the C<logs> point.  The new point
also carries C<copied_fields> from the event, which say which run and which
call it belongs to.  It goes to the retention policy C<details>, which keeps
it for C<detail_retention>.  The C<logs> point keeps everything else for the
C<retention> of C<grafana>.  So once a failure is older than
C<detail_retention>, its counts and timings remain, and what it was about is
gone.

To read both in one query, join them on C<copied_fields>.  The C<details>
policy is not the default, so InfluxQL names it: C<"details"."logs_detail">.

=head2 It listens on the network, and that is the point

The senders are other guests, so the input binds every address, and the ufw
profile of this recipe opens C<port>.  C<rate_limits> holds each sender to a
rate.  The firewall of the fleet is what keeps strangers out.  This recipe
adds no TLS and no authentication, so put it only on a guest that the
internet cannot reach on C<port>.

A sender needs the port opened outwards too, because the guests deny outgoing
traffic by default.  The recipe that configures the sender does that, as
L<Provisioner::Recipe::clod> does with C<telemetry>.

=cut

=head1 METHODS

=head2 %required = $recipe->required_recipes(%opts)

Returns C<grafana>, with the retention policy C<details> for
C<detail_retention>.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # The default is also here, not only in args, because this is called before
    # anything is validated.
    my $keep = $opts{detail_retention} // '48h';
    return ( grafana => sub { ( retention_policies => { details => $keep } ) } );
}

=head2 %limits = $recipe->rate_limits(%opts)

The OTLP port, at 256 new connections a second from one sender, the limit
that L<Provisioner::Recipe::logcollector> gives the other stream of the
fleet.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, as required_recipes does.
    return ( ( $opts{port} // 4317 ) => 256 );
}

=head2 $bool = $recipe->is_multi_tenant()

False.  There is one telegraf, one input and one processor on the machine.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

=over 4

=item * C<port>: the port of the OTLP input, on every address.

=item * C<detail_retention>: how long the details of an event stay, as an
InfluxDB duration.  See L</The details expire first>.

=item * C<detail_fields>: the fields that the processor moves to
C<logs_detail>.  The default is every attribute that C<OTEL_LOG_USER_PROMPTS>
and C<OTEL_LOG_TOOL_DETAILS> add to an event of Claude Code that can carry
free text, and the attributes that name the account of Claude Code, which
every event carries.  So after C<detail_retention>, an event no longer says
whose run it was.

=item * C<copied_fields>: the fields that the processor copies to
C<logs_detail> as well, so that a detail can be joined to its event.

=item * C<tag_fields>: the attributes that become tags rather than fields.
Each value of a tag is a series in InfluxDB, so name only attributes with few
values.

=back

=cut

sub args {
    my $field = { type => 'string', pattern => "$ATTRIBUTE" };
    return (
        type       => 'object',
        properties => {
            port => {
                type        => 'integer',
                default     => 4317,
                minimum     => 1024,
                maximum     => 65535,
                description => 'Port of the OTLP input over gRPC, on every address.',
            },
            detail_retention => {
                type        => 'string',
                pattern     => "$Trog::Patterns::INFLUX_DURATION",
                default     => '48h',
                description => 'How long the details of an event stay, as an InfluxDB duration.',
            },
            detail_fields => {
                type        => 'array',
                items       => $field,
                default     => [qw{prompt prompt_text response tool_parameters tool_input error user.email user.id user.account_uuid user.account_id organization.id}],
                description => 'Fields moved out of each logs point into a logs_detail point that expires after detail_retention.',
            },
            copied_fields => {
                type        => 'array',
                items       => $field,
                default     => [qw{session.id prompt.id tool_use_id event.sequence clod.job_id clod.attempt}],
                description => 'Fields copied into each logs_detail point, so that it joins to its event.',
            },
            tag_fields => {
                type        => 'array',
                items       => $field,
                default     => [qw{event.name tool_name decision clod.task clod.repo}],
                description => 'Attributes that become tags, which a dashboard groups by.  Only attributes with few values.',
            },
        },
    );
}

=head2 %files = $recipe->template_files()

The telegraf fragment, the processor that it loads, and the ufw profile.

=cut

sub template_files {
    return (
        'grafanaotel.telegraf.tt' => 'grafanaotel_telegraf.conf',
        'grafanaotel.details.tt'  => 'grafanaotel_details.star',

        # Rendered here, not by ufw, because ufw does not know the port.
        'grafanaotel.ufw.conf.tt' => 'grafanaotel_ufw.conf',
    );
}

=head2 @tests = $recipe->tests()

=cut

sub tests { return ('grafanaotel.tt') }

1;
