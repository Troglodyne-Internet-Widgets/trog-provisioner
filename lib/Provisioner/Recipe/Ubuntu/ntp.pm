package Provisioner::Recipe::Ubuntu::ntp;

#ABSTRACT: What ntp needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::ntp};

=head1 NAME

Provisioner::Recipe::Ubuntu::ntp - Ubuntu's C<deps> and C<dep_conflicts> for L<Provisioner::Recipe::ntp>.

=cut

sub deps {
    return qw{chrony};
}

sub dep_conflicts {
    return qw{ntp ntpdate systemd-timesyncd};
}

1;
