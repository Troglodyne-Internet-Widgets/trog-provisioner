package Provisioner::Recipe::Ubuntu::ufw;

#ABSTRACT: What ufw needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::ufw};

=head1 NAME

Provisioner::Recipe::Ubuntu::ufw - Ubuntu's C<deps> for L<Provisioner::Recipe::ufw>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else ufw does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{ufw};
}

1;
