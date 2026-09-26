package Provisioner::Recipe::Ubuntu::nginx;

#ABSTRACT: What nginx needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::nginx};

=head1 NAME

Provisioner::Recipe::Ubuntu::nginx - Ubuntu's C<deps> for L<Provisioner::Recipe::nginx>.

=cut

sub deps {
    return qw{nginx-full};
}

=head2 @pkgs = $recipe->dep_conflicts()

C<apache2>, which C<libapache2-mod-php> brings in as the first of its choices,
and which would bind the ports of nginx.

=cut

sub dep_conflicts {
    return qw{apache2};
}

1;
