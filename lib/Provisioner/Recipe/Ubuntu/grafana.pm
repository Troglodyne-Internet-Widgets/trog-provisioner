package Provisioner::Recipe::Ubuntu::grafana;

#ABSTRACT: What grafana needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::grafana};

=head1 NAME

Provisioner::Recipe::Ubuntu::grafana - Ubuntu's C<deps> and archives for L<Provisioner::Recipe::grafana>.

=head1 DESCRIPTION

C<influxdb> comes from Ubuntu, and C<grafana> and C<telegraf> from the archives
of their vendors, which C<package_sources> below names.
L<Provisioner::Recipe::grafana/InfluxDB 1.x, and why that is not an accident>
says why C<influxdb> does not come from its vendor.

=cut

sub deps {
    return qw{influxdb grafana telegraf curl};
}

=head2 @sources = $recipe->package_sources()

The archives of Grafana and InfluxData.  InfluxData also publishes
C<influxdb>, at a version above the one in Ubuntu.  So its archive pins that
package below every other, and apt keeps the one from Ubuntu.

=cut

sub package_sources {
    return (
        {
            name       => 'grafana',
            uri        => 'https://apt.grafana.com',
            suites     => ['stable'],
            components => ['main'],
            key        => 'https://apt.grafana.com/gpg.key',
        },
        {
            name => 'influxdata',
            uri  => 'https://repos.influxdata.com/debian',

            # influxdata-archive.key, not influxdata-archive_compat.key.  Much of
            # the published guidance still names the compat key, which expired
            # in January 2026.
            key        => 'https://repos.influxdata.com/influxdata-archive.key',
            suites     => ['stable'],
            components => ['main'],
            pin        => { packages => 'influxdb', priority => -1 },
        },
    );
}

1;
