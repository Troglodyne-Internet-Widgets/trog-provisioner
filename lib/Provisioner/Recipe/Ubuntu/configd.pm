package Provisioner::Recipe::Ubuntu::configd;

#ABSTRACT: What configd needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::configd};

=head1 NAME

Provisioner::Recipe::Ubuntu::configd - Ubuntu's C<deps> for L<Provisioner::Recipe::configd>.

=cut

sub deps {
    return qw{cpanminus make};
}

1;
