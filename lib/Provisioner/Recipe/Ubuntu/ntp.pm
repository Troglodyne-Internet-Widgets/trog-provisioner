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

=head2 @pkgs = $recipe->deps()

C<chrony>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{chrony};
}

=head2 @pkgs = $recipe->dep_conflicts()

C<ntp>, C<ntpdate> and C<systemd-timesyncd>, the other clients of NTP, which
the packager keeps off the guest.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->dep_conflicts();

=cut

sub dep_conflicts {
    return qw{ntp ntpdate systemd-timesyncd};
}

1;
