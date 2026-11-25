package Provisioner::Recipe::Ubuntu::zswap;

#ABSTRACT: What zswap needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::zswap};

=head1 NAME

Provisioner::Recipe::Ubuntu::zswap - Ubuntu's C<deps> for L<Provisioner::Recipe::zswap>.

=cut

=head2 $recipe->deps()

C<systemd-oomd>, which kills a runaway first.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{systemd-oomd};
}

1;
