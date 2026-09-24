package Provisioner::Recipe::grafana;

#ABSTRACT: Grafana over InfluxDB and Telegraf, behind the domain's nginx.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

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
added the way C<matrix>, C<plexmediaserver> and C<admincode> add theirs.  Only
C<influxdb> can be a C<deps> entry.  Cloud-init installs C<deps> at first boot,
before this recipe configures an archive.

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

=head2 The dashboards survive a rebuild because they are not kept

Nothing here is in C<remote_files>, and that is deliberate for the dashboards.
Grafana provisions them from files in F</etc/grafana/provisioning>, so a rebuilt
guest draws the same ones and nothing is carried over.  A rebuild loses the
measurements and anything that an operator made by hand in the UI.

The recipe that depends on this one keeps those if it wants them.  That recipe
knows what it put in the database and whether a loss matters.  So it names what
to carry over in its own C<remote_files>, and this recipe does not salvage a
database for every recipe that uses it.

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

sub args {
    return (
        type       => 'object',
        required   => [qw{admin_password}],
        properties => {
            admin_password => {
                type        => 'string',
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
                pattern     => '^[0-9]+[smhdw]$',
                default     => '90d',
                description => 'How long measurements are kept, as an InfluxDB duration such as 90d.',
            },
            home_dashboard => {
                type        => 'string',
                pattern     => '^[^/]+[.]json$',
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
    );
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
