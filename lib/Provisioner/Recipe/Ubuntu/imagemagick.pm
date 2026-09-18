package Provisioner::Recipe::Ubuntu::imagemagick;

#ABSTRACT: What imagemagick needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::imagemagick};

=head1 NAME

Provisioner::Recipe::Ubuntu::imagemagick - Ubuntu's C<deps> for L<Provisioner::Recipe::imagemagick>.

=cut

sub deps {
    return qw{ghostscript libjpeg-dev libpng-dev libtiff-dev liblzma-dev libxml2-dev libdjvulibre-dev libfreetype-dev libperl-dev libjxl-dev libtcmalloc-minimal4t64 g++ pkg-config};
}

1;
