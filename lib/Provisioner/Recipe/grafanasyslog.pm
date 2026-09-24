package Provisioner::Recipe::grafanasyslog;

#ABSTRACT: Put the collector's syslog stream into influxdb, and a dashboard over it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::grafanasyslog - the logs of the fleet, drawn.

=head1 SYNOPSIS

    logs.example.test:
        logcollector: ~
        grafana:
            admin_password: secret:grafana/logs.example.test/password
        grafanasyslog: ~

This recipe pulls in C<grafana>, but it does not supply the C<admin_password>
of that recipe.  The operator chooses a password.  This recipe does not invent
one for a vhost that faces the internet.  So you configure C<grafana> next to
it, as above.  If a domain leaves it out, the schema of C<grafana> refuses the
domain.  The build does not continue with an administrator password that is
easy to guess.

=head1 DESCRIPTION

Gives L<Provisioner::Recipe::grafana> data to draw.  This recipe adds three
things: a telegraf syslog input on loopback, a forward from the collector that
sends it a copy of each message, and the published syslog dashboard.

C<grafana> installs and configures the stack: telegraf, influxd and grafana.
This recipe is the only thing that knows that the stack reads syslog.  If a
different recipe wants other data in the same database, it writes its own
telegraf fragment and its own dashboard.  It changes nothing here.

=head2 It belongs on the collector itself

C<logcollector> is in C<required_recipes>.  So when you configure this recipe,
it also configures the forward.  An operator does not set the forward by hand
at the other end.  If you add this recipe to a guest, that guest becomes a
collector that listens for the fleet.  Use this recipe only on the machine that
is already the collector.

=head2 Over a port, not out of the files

The collector writes the messages from each sender to a file.  Telegraf can read
those files without a forward, but they are the wrong source.  In the file, a
message is a line of text, and the structure is gone.  The dashboard needs the
severity, facility, hostname and appname as tags.  Telegraf parses RFC5424 and
gets all four.  That is why the collector forwards the copy before it writes
the file.

The forward goes over loopback.  So nothing goes on the wire, and no firewall
profile is necessary.  See
L<Provisioner::Recipe::logcollector/Forwarding a copy, for something on this guest>
for the other end.  That section also tells why the forward comes above the
C<stop>.

=head2 The dashboard names its datasource, and something has to agree

Dashboard 12433 refers to its datasource by name.  When grafana loads an
exported dashboard from a file, it does not replace the C<${DS_*}> placeholders.
So this recipe writes the name into the JSON when it renders the template.  That
name must be the name that C<grafana> gave to the datasource it provisioned.
Two recipes hold the same string.  Both set it as C<default>, and a subtest in
F<t/recipes.t> makes sure that the two values are equal.

=head2 When two recipes ask for a forward

The C<forward> that this recipe adds never goes to C<resolve_conflict>.  Most
disagreements between two dependents do.  C<reconcile> settles fields that hold
plain scalars on both sides, and L<Hash::Merge> merges the rest.  An array is
part of the rest.  So if an operator also points the collector at a destination
of their own, the collector gets both destinations.  It does not refuse.  Two
parties that each want a copy of the stream can both have one.

If both ends name the same destination, the merge joins the two lists as they
are.  The collector then gets the same C<omfwd> twice and sends each message to
that port twice.  L<Provisioner::Recipe::logcollector> removes the repeated
destinations.

=cut

=head1 METHODS

=head2 %required = $recipe->required_recipes(%opts)

Returns C<grafana> for the stack, and C<logcollector> for the stream.  It
configures C<logcollector> with the forward that points to this recipe.  It
makes the syslog dashboard the C<home_dashboard> of C<grafana>, so that the
dashboard is what an operator sees after a login.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # The default is also here, not only in args, because this is called before
    # anything is validated.
    my $port = $opts{port} // 6514;

    # syslog.json is the name that the global fragment installs the dashboard as.
    return (
        grafana      => sub { ( home_dashboard => 'syslog.json' ) },
        logcollector => sub { ( forward        => ["127.0.0.1:$port"] ) },
    );
}

=head2 @claims = $recipe->listens(%opts)

The syslog input of telegraf on C<port>, on 127.0.0.1.

=cut

sub listens {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, as required_recipes does.
    return ( "127.0.0.1:" . ( $opts{port} // 6514 ) );
}

=head2 $bool = $recipe->is_multi_tenant()

False.  There is one telegraf input on one port, one dashboard, and one
collector that forwards to it.  A second domain describes the same stream again.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

=over 4

=item * C<port>: the loopback port where telegraf accepts the forwarded
stream.  It is also the port that the collector sends to.  Both ends read one
setting, so they cannot disagree.

=item * C<datasource>: the grafana datasource that the dashboard reads.  It
must be the name that L<Provisioner::Recipe::grafana> gave it.  See
L</The dashboard names its datasource, and something has to agree>.

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

Returns the telegraf fragment and the dashboard, each as template name to
output file name.

=cut

sub template_files {
    return (
        'grafanasyslog.telegraf.tt'  => 'grafanasyslog_telegraf.conf',
        'grafanasyslog.dashboard.tt' => 'grafanasyslog_dashboard.json',
    );
}

=head2 @tests = $recipe->tests()

Returns the template for the test that runs on the guest.

=cut

sub tests { return ('grafanasyslog.tt') }

1;
