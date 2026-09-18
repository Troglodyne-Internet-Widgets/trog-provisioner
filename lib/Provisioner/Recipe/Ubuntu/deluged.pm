package Provisioner::Recipe::Ubuntu::deluged;

#ABSTRACT: What deluged needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::deluged};

=head1 NAME

Provisioner::Recipe::Ubuntu::deluged - Ubuntu's C<deps> for L<Provisioner::Recipe::deluged>.

=cut

sub deps {
    return qw{deluged deluge-web};
}

1;
