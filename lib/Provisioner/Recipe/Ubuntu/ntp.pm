package Provisioner::Recipe::Ubuntu::ntp;

#ABSTRACT: What ntp needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::ntp};

=head1 NAME

Provisioner::Recipe::Ubuntu::ntp - Ubuntu's C<deps> and C<dep_conflicts> for L<Provisioner::Recipe::ntp>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else ntp does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{chrony};
}

sub dep_conflicts {

    # Remove anything that conflicts with chrony
    return qw{ntp ntpdate systemd-timesyncd};
}

1;
