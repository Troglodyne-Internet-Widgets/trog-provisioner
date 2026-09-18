package Provisioner::Recipe::Ubuntu::autoupdate;

#ABSTRACT: What autoupdate needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::autoupdate};

=head1 NAME

Provisioner::Recipe::Ubuntu::autoupdate - Ubuntu's C<deps> for L<Provisioner::Recipe::autoupdate>.

=cut

sub deps {
    return qw{};
}

1;
