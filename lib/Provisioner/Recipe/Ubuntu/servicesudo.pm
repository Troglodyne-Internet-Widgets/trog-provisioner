package Provisioner::Recipe::Ubuntu::servicesudo;

#ABSTRACT: What servicesudo needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::servicesudo};

=head1 NAME

Provisioner::Recipe::Ubuntu::servicesudo - Ubuntu's C<deps> for L<Provisioner::Recipe::servicesudo>.

=cut

=head2 $recipe->deps()

C<sudo>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{sudo};
}

1;
