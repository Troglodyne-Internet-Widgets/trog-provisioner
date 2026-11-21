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

sub deps {
    return qw{systemd-oomd};
}

1;
