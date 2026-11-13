package Provisioner::Recipe::grafana;

#ABSTRACT: Grafana over InfluxDB and Telegraf, behind the domain's nginx.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Trog::Patterns();

=head1 NAME

Provisioner::Recipe::grafana - dashboards, and the metrics store behind them.

=head1 SYNOPSIS

    dash.example.test:
        grafana:
            admin_password: somepassword
            retention: 90d

=head1 DESCRIPTION

Installs the three parts of a metrics stack on one guest: C<telegraf> collects,
C<influxdb> stores, and C<grafana> draws.  This recipe does not decide what
telegraf collects.  Telegraf reads F</etc/telegraf/telegraf.d>, and a recipe that
wants something in the database writes a fragment there.
L<Provisioner::Recipe::grafanasyslog> is one recipe that does.

=head2 InfluxDB 1.x, and why that is not an accident

C<influxdb> in noble is 1.6.7, which speaks InfluxQL, not Flux.  This recipe
wants that version.  The published dashboards for host and syslog metrics use
InfluxQL, and with 2.x every query in them needs a port.  It is also the only one
of the three that comes from the distribution.

=head2 Two archives, because neither package exists here

No Ubuntu component has C<telegraf> or C<grafana>, and C<apt-cache policy>
reports no candidate for either.  So each comes from the archive of its vendor,
which L<Provisioner::Recipe::Ubuntu::grafana> names.  cloud-init adds both
archives and installs all three packages at first boot.

=head2 It answers on loopback rather than on a socket

C<grafana> listens on C<127.0.0.1> and nginx proxies to it.
L<Provisioner::Recipe::gogs> does the same, for the same reason.  Here a unix
socket is the usual preference, and the obstacle is ownership, not taste.
Grafana runs as its packaged C<grafana> account and nginx runs as C<www-data>.
A socket under C<install_dir> is below a directory that the C<data> target
leaves C<0750> and owned by the service user.  So a socket needs group
membership across three accounts and a recursive chmod.  A loopback port needs
neither.  Nothing outside the guest can reach the port, so this recipe has no
firewall profile and opens nothing.

=head2 What a rebuild keeps

Grafana provisions the dashboards from files in F</etc/grafana/provisioning>,
so a rebuilt guest draws the same ones, and nothing of them is carried over.
Anything that an operator made by hand in the UI is lost.

The measurements are carried over.  The database is one for every recipe
that writes to it, so this recipe salvages it whole, and a recipe that adds a
telegraf fragment needs nothing more.  C<remote_prepare> runs
F<grafana-salvage.sh>, which asks influxd for a portable backup of
C<influx_database>.  A copy of the files of a running influxd is not one,
because it can take a shard halfway through a compaction.  The backup comes
down with the other state of the domain.

A postrun task of the rebuilt guest, F<grafana_influx_restore.sh>, gives it to
influxd again, before the setup script holds the database to C<retention>.  It
restores only into a database that this build made, which it knows by the
duration of C<autogen>: telegraf makes a database with none, and the setup
script gives every database one.  So a provision of a guest that already
holds measurements leaves them as they are.  The restore drops the database
of the new guest first.  That loses what telegraf collected on it since its
first boot, and nothing that any other guest sent, because the inputs for the
fleet start after the restore.

=cut

=head1 METHODS

=head2 %required = $recipe->required_recipes(%opts)

Returns C<nginxproxy>, in front.  Grafana answers on loopback, and something
must serve the domain.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because required_recipes runs before
    # validation.
    my $port = $opts{port} // 3000;
    my $ipv6 = $opts{ipv6} // 1;

    return (
        nginxproxy => sub {
            (
                vhosts => {
                    80  => { ssl_redirect => 1, ipv6 => 1 },
                    443 => {
                        ssl       => 1,
                        proxy_uri => "http://127.0.0.1:$port",
                        ipv6      => $ipv6,
                    },
                },
            )
        },
    );
}

=head2 @claims = $recipe->listens(%opts)

grafana on C<port>, and influxd on 8086 for queries and on 8088 for backups,
all three on 127.0.0.1.

=cut

sub listens {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, as required_recipes does.
    return ( "127.0.0.1:" . ( $opts{port} // 3000 ), "127.0.0.1:8086", "127.0.0.1:8088" );
}

=head2 $bool = $recipe->is_multi_tenant()

False.  The machine has one grafana, one influxd and one telegraf.  This recipe
writes each of their configuration files to a fixed path, so a second domain
overwrites what the first wrote.  C<root_url> also names one domain.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

=over 4

=item * C<admin_password> -- B<required>, no default.  Grafana ships with
C<admin>/C<admin> and asks for a new password at the first login.  Nobody is at
that prompt on a provisioned guest.  So the account keeps the password that the
grafana documentation publishes, on a vhost that faces the internet.

=item * C<grafana_admin> -- the account name of the grafana administrator.  It is
not C<admin_user>, which is the administrator of the guest.

=item * C<port> -- the loopback port that grafana answers on and nginx proxies
to.  See L</It answers on loopback rather than on a socket>.

=item * C<influx_database> -- the database telegraf writes to and grafana reads.

=item * C<datasource_name> -- the name of the datasource in grafana.  A dashboard
refers to its datasource by name.  So L<Provisioner::Recipe::grafanasyslog> puts
this exact string into the dashboard it installs, and C<t/recipes.t> makes sure
that the two agree.

=item * C<retention> -- how long InfluxDB keeps a measurement, as an InfluxDB
duration.  The setup script creates the database with this retention.  Telegraf
creates a missing database with no expiry, and a syslog firehose with no expiry
fills the disk.

=item * C<retention_policies> -- more retention policies in the database, as a
map from the name of each to an InfluxDB duration.  The setup script creates
each one, and sets its duration on a database that has it already.  A telegraf
fragment sends a point to one of them with the tag
C<influxdb_retention_policy>, which the output of this recipe reads and does
not store.  A point without the tag goes to the default policy, which keeps it
for C<retention>.  L<Provisioner::Recipe::grafanaotel> asks for one, to keep
the details of the events of claude for less time than the events.  Empty by
default.

=item * C<home_dashboard> -- the file in F</var/lib/grafana/dashboards> that
grafana shows after a login.  No default.  Without it, the home page lists only
starred and recently viewed dashboards.  A provisioned dashboard is neither on a
new guest, so the page is empty and the dashboard is one menu away.  Grafana 13
serves the home page from a copy of the file, under the identifier
C<default-home-dashboard>, and reads the file again for each visit.  So the
address differs from the one the file provider gives the same dashboard, but the
contents do not.  L<Provisioner::Recipe::grafanasyslog> sets this to its own
dashboard.  If two recipes name different files, the build stops, because only
one dashboard can be the home page.

=back

=cut

# The name of a retention policy, which the setup script writes unquoted.
my $POLICY_NAME = qr/\A [[:lower:]] [[:lower:][:digit:]_]* \z/;

# The name of a JSON file, with no directory.
my $JSON_FILE = qr/\A [^\/]+ [.] json \z/;

sub args {
    return (
        type       => 'object',
        required   => [qw{admin_password}],
        properties => {
            admin_password => {
                type        => 'string',
                'x-secret'  => 1,
                description => 'Password for the grafana administrator.  No default on purpose: see the POD.',
            },
            grafana_admin => {
                type        => 'string',
                default     => 'admin',
                description => "Grafana's own administrator account.  Distinct from admin_user, which administers the guest.",
            },
            port => {
                type        => 'integer',
                default     => 3000,
                minimum     => 1024,
                maximum     => 65535,
                description => 'Loopback port grafana answers on, which nginx proxies to.',
            },
            influx_database => {
                type        => 'string',
                default     => 'telegraf',
                description => 'InfluxDB database telegraf writes to and the datasource reads.',
            },
            datasource_name => {
                type        => 'string',
                default     => 'InfluxDB',
                description => 'What the provisioned datasource is called in grafana.  A dashboard names its datasource by this string, so grafanasyslog must agree with it.',
            },
            retention => {
                type        => 'string',
                pattern     => "$Trog::Patterns::INFLUX_DURATION",
                default     => '90d',
                description => 'How long measurements are kept, as an InfluxDB duration such as 90d.',
            },
            retention_policies => {
                type                 => 'object',
                default              => {},
                propertyNames        => { pattern => "$POLICY_NAME" },
                additionalProperties => { type    => 'string', pattern => "$Trog::Patterns::INFLUX_DURATION" },
                description          => 'More retention policies, name to InfluxDB duration, that a telegraf fragment sends a point to with the tag influxdb_retention_policy.',
            },
            home_dashboard => {
                type        => 'string',
                pattern     => "$JSON_FILE",
                description => 'File name, in /var/lib/grafana/dashboards, of the dashboard grafana opens on after a login.  Unset leaves the stock home page.',
            },
            ipv6 => {
                type        => 'boolean',
                default     => 1,
                description => 'Whether the vhost in front of this listens on IPv6.',
            },
        },
    );
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return (
        'grafana.ini.tt'          => 'grafana.ini',
        'grafana.influxdb.env.tt' => 'grafana_influxdb.env',
        'grafana.datasource.tt'   => 'grafana_datasource.yaml',
        'grafana.dashboards.tt'   => 'grafana_dashboards.yaml',

        # Telegraf ships with no output, so without this it drops all it collects.
        'grafana.telegraf.tt' => 'grafana_telegraf.conf',

        # A script, not fragment lines, because it polls influxd and a makefile
        # fragment runs each line in its own shell.
        'grafana.influx-setup.sh.tt' => 'grafana_influx_setup.sh',

        # The two halves of the salvage of the measurements.
        'grafana.salvage.sh.tt' => 'grafana-salvage.sh',
        'grafana.restore.sh.tt' => 'grafana_influx_restore.sh',
    );
}

=head2 @commands = $recipe->remote_prepare($install_dir, $domain)

Runs F<grafana-salvage.sh>, which writes a portable backup of
C<influx_database> to F<.grafana-salvage/influxdb>.  See L</What a rebuild
keeps>.  On a guest built before this recipe had the script, the command
fails, and the salvage keeps what it had.

=cut

sub remote_prepare {
    my ( $self, $install_dir, $domain ) = @_;
    return ("$install_dir/$domain/grafana-salvage.sh");
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

The backup that C<remote_prepare> made.  It lands in F<grafana-salvage> of the
domain directory, where the restore reads it.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return ( "$install_dir/$domain/.grafana-salvage/" => 'grafana-salvage/' );
}

=head2 %jails = $recipe->jails()

A jail that bans a host whose logins fail too often.  grafana logs each request
to its log file, with the address that nginx forwarded:

    logger=context userId=0 orgId=0 uname= t=2026-09-19T16:22:14.270753469Z level=info msg="Request Completed" method=POST path=/login status=401 remote_addr=192.168.122.57 time_ms=25 ...

The filter that fail2ban ships for grafana looks for a message that grafana no
longer writes.

=cut

sub jails {
    return (
        'grafana-login' => {
            filter    => '',
            backend   => 'auto',
            port      => 'http,https',
            logpath   => '/var/log/grafana/grafana.log',
            failregex => '^logger=context .* msg="Request Completed" method=POST path=/login status=401 remote_addr=<HOST>',
        },
    );
}

=head2 @hosts = $recipe->fetch_hosts()

The two vendor archives.  C<influxdb> is not here, because it comes from the
mirror of the distribution, which every guest already reaches.

=cut

sub fetch_hosts {
    return (qw{apt.grafana.com repos.influxdata.com});
}

=head2 @classes = $recipe->cache_classes()

Both archives, as apt repositories.

=cut

sub cache_classes {
    my ($class) = @_;

    return map { $class->apt_repo_classes($_) } $class->fetch_hosts();
}

=head2 @tests = $recipe->tests()

=cut

sub tests { return ('grafana.tt') }

1;
