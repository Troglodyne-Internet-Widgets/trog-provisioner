package Provisioner::Recipe::Ubuntu::perllsp;

#ABSTRACT: What perllsp needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::perllsp};

=head1 NAME

Provisioner::Recipe::Ubuntu::perllsp - Ubuntu's C<deps> for L<Provisioner::Recipe::perllsp>.

=cut

=head2 $recipe->deps()

C<nodejs> and C<npm>, which install PerlNavigator, and C<vim>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{nodejs npm vim};
}

1;
