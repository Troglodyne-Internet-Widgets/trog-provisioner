package Provisioner::Recipe::grafanasyslog;

#ABSTRACT: Put the collector's syslog stream into influxdb, and a dashboard over it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util qw{any};

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::grafanasyslog - the fleet's logs, drawn.

=head1 SYNOPSIS

    logs.example.test:
        logcollector: ~
        grafana:
            admin_password: secret:grafana/logs.example.test/password
        grafanasyslog: ~

C<grafana> is pulled in by this recipe, but its C<admin_password> is not supplied
with it and cannot be: a password is the operator's to choose, and nothing here
is entitled to invent one for a vhost that faces the internet.  So C<grafana> is
configured alongside, as above, and a domain that leaves it out is refused by
that recipe's schema rather than built with a guessable administrator.

=head1 DESCRIPTION

Gives L<Provisioner::Recipe::grafana> something to draw: a telegraf syslog input
on loopback, the collector forwarding a copy of everything it receives into it,
and the published syslog dashboard over the result.

The split is that C<grafana> installs and configures the stack -- telegraf,
influxd and grafana itself -- while this recipe is the one thing that knows the
stack is being pointed at syslog.  Another recipe wanting something else in the
same database writes its own telegraf fragment and its own dashboard, and
changes nothing here.

=head2 It belongs on the collector itself

C<logcollector> is in C<required_recipes>, so configuring this recipe wires the
forward up rather than leaving an operator to set it by hand at the other end.
That is worth knowing before adding it to an arbitrary guest: it would make that
guest a collector, listening for the fleet.  This is a recipe for the machine
that already is one.

C<enrich> refuses a domain with no C<logcollector> in its modules.  With the
requirement above in place the depsolver will have just added it, so that is a
guard on an invariant rather than the mechanism -- it earns its three lines by
failing a configuration assembled some other way with a sentence naming the
problem, instead of producing a dashboard with nothing behind it.

=head2 Over a port, not out of the files

The collector already writes every sender's messages to a file, so reading those
would need no forward at all.  It is the wrong source: by then a message is a
line of text with the structure parsed out of it, and the dashboard needs the
severity, facility, hostname and appname as tags.  Telegraf parses RFC5424 and
gets all of them, which is why the copy is forwarded before it is filed.

Loopback, so nothing is on the wire and no firewall profile is needed.  See
L<Provisioner::Recipe::logcollector/Forwarding a copy, for something on this guest>
for the other end of it, including why the forward is emitted above the C<stop>.

=head2 The dashboard names its datasource, and something has to agree

Dashboard 12433 refers to its datasource by name.  Grafana does not substitute
the C<${DS_*}> placeholders an exported dashboard carries when it loads one from
a file, so the name is written into the JSON at render time -- and it has to be
the name C<grafana> gave the datasource it provisioned.  One string in two
recipes, which is what C<default> on both and a subtest in F<t/recipes.t> pinning
them together is for.

=head2 When two recipes ask for a forward

The C<forward> this injects never reaches C<resolve_conflict>, which is worth
knowing because most disagreements between two dependents do.  C<reconcile>
settles fields that are plain scalars on both sides and leaves the rest to
L<Hash::Merge>, and an array is the rest -- so an operator who has also pointed
the collector at something of their own keeps both destinations rather than
getting a refusal.  Two parties each wanting a copy of the stream is a request
that can be granted whole, so it is.

Naming the same destination at both ends is the case that needed handling:
concatenation is literal, so the collector would be given the identical
C<omfwd> twice and would send every message to that port twice.
L<Provisioner::Recipe::logcollector> discards the repeats.

=cut

=head1 METHODS

=head2 %required = $recipe->required_recipes(%opts)

C<grafana> for the stack, and C<logcollector> for the stream -- configured with
the forward that points it here.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because required_recipes is asked
    # before anything has been validated.
    my $port = $opts{port} // 6514;

    return (
        grafana      => sub { () },
        logcollector => sub { ( forward => ["127.0.0.1:$port"] ) },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Refuses a domain whose modules have no C<logcollector>.  See
L</It belongs on the collector itself>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    die "The grafanasyslog recipe draws what logcollector receives, and " . ( $opts{domain} // 'this domain' ) . " has no logcollector to receive anything.\n"
      unless any { $_ eq 'logcollector' } @{ $opts{modules} // [] };

    return %opts;
}

=head2 $bool = $recipe->is_multi_tenant()

False.  One telegraf input on one port, one dashboard, and one collector
forwarding into it.  A second domain would be describing the same stream twice.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

=over 4

=item * C<port> -- the loopback port telegraf accepts the forwarded stream on,
and the port the collector is configured to send to.  One setting for both ends,
so they cannot disagree.

=item * C<datasource> -- the grafana datasource the dashboard reads.  Must be
what L<Provisioner::Recipe::grafana> called it; see L</The dashboard names its
datasource, and something has to agree>.

=back

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            port => {
                type        => 'integer',
                default     => 6514,
                minimum     => 1024,
                maximum     => 65535,
                description => 'Loopback port telegraf reads the forwarded syslog stream on, and the port logcollector is told to forward to.',
            },
            datasource => {
                type        => 'string',
                default     => 'InfluxDB',
                description => "The grafana datasource the dashboard reads.  Must match the grafana recipe datasource_name, which t/recipes.t checks.",
            },
        },
    );
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return (
        'grafanasyslog.telegraf.tt'  => 'grafanasyslog_telegraf.conf',
        'grafanasyslog.dashboard.tt' => 'grafanasyslog_dashboard.json',
    );
}

=head2 @tests = $recipe->tests()

=cut

sub tests { return ('grafanasyslog.tt') }

1;
