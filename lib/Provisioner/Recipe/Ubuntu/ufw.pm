package Provisioner::Recipe::Ubuntu::ufw;

#ABSTRACT: What ufw needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::ufw};

=head1 NAME

Provisioner::Recipe::Ubuntu::ufw - Ubuntu's C<deps> for L<Provisioner::Recipe::ufw>.

=cut

sub deps {
    return qw{ufw};
}

1;
