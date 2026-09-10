package Provisioner::Recipe::Ubuntu::nginx;

#ABSTRACT: What nginx needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::nginx};

=head1 NAME

Provisioner::Recipe::Ubuntu::nginx - Ubuntu's C<deps> for L<Provisioner::Recipe::nginx>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else nginx does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{nginx-full};
}

1;
