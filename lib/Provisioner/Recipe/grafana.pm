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

Installs the three halves of a metrics stack on one guest: C<telegraf> collects,
C<influxdb> stores, and C<grafana> draws.  Nothing here decides what is
collected -- telegraf reads F</etc/telegraf/telegraf.d>, and a recipe wanting
something in the database writes a fragment there.
L<Provisioner::Recipe::grafanasyslog> is the one that does.

=head2 InfluxDB 1.x, and why that is not an accident

C<influxdb> in noble is 1.6.7, which speaks InfluxQL rather than Flux.  That is
the version this wants: the published dashboards for host and syslog metrics are
written against InfluxQL, and 2.x would mean porting every query in them.  It is
also the only one of the three that comes from the distribution.

=head2 Two archives, because neither package exists here

C<telegraf> and C<grafana> are in no Ubuntu component at all -- C<apt-cache
policy> reports no candidate for either -- so each comes from its vendor's
archive, added the way C<matrix>, C<plexmediaserver> and C<admincode> add theirs.
Only C<influxdb> can be a C<deps> entry, because C<deps> is installed by
cloud-init at first boot, before any of this has configured an archive.

=head2 It answers on loopback rather than on a socket

C<grafana> listens on C<127.0.0.1> and nginx proxies to it, which is what
L<Provisioner::Recipe::gogs> does and for the same reason.  A unix socket would
be the usual preference here, and the obstacle is ownership rather than taste:
grafana runs as its packaged C<grafana> account, nginx as C<www-data>, and a
socket under C<install_dir> sits below a directory the C<data> target leaves
C<0750> owned by the service user -- so it takes a three-way arrangement of
group membership and a recursive chmod to do what a loopback port does with
none.  Nothing outside the guest can reach the port: it is bound to loopback, so
there is no firewall profile here and nothing to open.

=head2 The dashboards survive a rebuild because they are not kept

Nothing here is in C<remote_files>, and that is deliberate for the dashboards:
they are provisioned from files in F</etc/grafana/provisioning>, so a rebuilt
guest draws the same ones without anything having been carried over.  What a
rebuild does lose is the measurements themselves and anything an operator made
by hand in the UI.  A guest where either matters wants C<remote_files>, which
this recipe does not yet have.

=cut

=head1 METHODS

=head2 %required = $recipe->required_recipes(%opts)

nginx, in front: grafana answers on loopback and something has to serve the
domain.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because required_recipes is asked
    # before anything has been validated.
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

=head2 $bool = $recipe->is_multi_tenant()

False.  One grafana, one influxd and one telegraf on the machine, each with a
single configuration file and no C<conf.d> between them that would let a second
domain say anything without overwriting what the first said.  C<root_url> names
one domain as well.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

=over 4

=item * C<admin_password> -- B<required>, no default.  Grafana ships with
C<admin>/C<admin> and asks for a new one at the first login, which is a prompt
nobody is standing at on a provisioned guest -- so the account would keep the
password its own documentation publishes, on a vhost facing the internet.

=item * C<grafana_admin> -- the administrator's account name.  Not C<admin_user>,
which is the guest's administrator and something else entirely.

=item * C<port> -- the loopback port grafana answers on, and what nginx is
pointed at.  See L</It answers on loopback rather than on a socket>.

=item * C<influx_database> -- the database telegraf writes to and grafana reads.

=item * C<datasource_name> -- what the datasource is called in grafana.  A
dashboard refers to its datasource by name, so
L<Provisioner::Recipe::grafanasyslog> substitutes this exact string into the
dashboard it installs; C<t/recipes.t> pins the two together.

=item * C<retention> -- how long a measurement is kept, as an InfluxDB duration.
The database is created with this before telegraf first writes, because telegraf
creates a missing one with no expiry at all -- and a syslog firehose with no
expiry is a disk that fills.

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

        # Telegraf ships no output at all, so without this it collects the host
        # metrics its own sample turns on and drops every one of them.
        'grafana.telegraf.tt' => 'grafana_telegraf.conf',

        # Waits for influxd and then creates the database with its retention.
        # A script rather than fragment lines because it polls, and a makefile
        # fragment runs each line in a shell of its own.
        'grafana.influx-setup.sh.tt' => 'grafana_influx_setup.sh',
    );
}

=head2 @hosts = $recipe->fetch_hosts()

The two vendor archives.  C<influxdb> is not here: it comes from the
distribution's own mirror, which every guest already reaches.

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
