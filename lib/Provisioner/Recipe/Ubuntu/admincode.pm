package Provisioner::Recipe::Ubuntu::admincode;

#ABSTRACT: What admincode needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::admincode};

=head1 NAME

Provisioner::Recipe::Ubuntu::admincode - Ubuntu's C<deps> for L<Provisioner::Recipe::admincode>.

=cut

sub deps {
    return qw{libpithub-perl git};
}

1;
