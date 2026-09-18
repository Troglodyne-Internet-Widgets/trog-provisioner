package Provisioner::Recipe::Ubuntu::claude;

#ABSTRACT: What claude needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::claude};

=head1 NAME

Provisioner::Recipe::Ubuntu::claude - Ubuntu's C<deps> for L<Provisioner::Recipe::claude>.

=cut

sub deps {
    return qw{nodejs npm};
}

1;
