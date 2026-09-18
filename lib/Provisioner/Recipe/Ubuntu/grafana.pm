package Provisioner::Recipe::Ubuntu::grafana;

#ABSTRACT: What grafana needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::grafana};

=head1 NAME

Provisioner::Recipe::Ubuntu::grafana - Ubuntu's C<deps> for L<Provisioner::Recipe::grafana>.

=head1 DESCRIPTION

This list holds one of the three services, C<influxdb>, and C<curl>.  No Ubuntu
component has C<grafana> or C<telegraf>.  Cloud-init installs C<deps> at first
boot, before the fragment adds either vendor archive, so the fragment installs
both.  A request for them here installs nothing and says nothing about it.
L<Provisioner::Recipe::grafana/Two archives, because neither package exists here>
describes that failure.

=cut

sub deps {
    return qw{influxdb curl};
}

1;
