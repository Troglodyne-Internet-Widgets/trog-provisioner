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

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else grafana does is in the recipe this
inherits from.

Only two of the three services are here.  C<grafana> and C<telegraf> are in no
Ubuntu component, and C<deps> is what cloud-init installs at first boot -- before
the fragment has added either vendor archive -- so both are installed by the
fragment instead.  Asking for them here would install nothing and say nothing
about it, which is the failure
L<Provisioner::Recipe::grafana/Two archives, because neither package exists here>
describes.

=cut

sub deps {
    return qw{influxdb curl};
}

1;
