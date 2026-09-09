package Provisioner::Recipe::Ubuntu::redis;

#ABSTRACT: What redis needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::redis};

=head1 NAME

Provisioner::Recipe::Ubuntu::redis - Ubuntu's C<deps> for L<Provisioner::Recipe::redis>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else redis does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{redis-server};
}

1;
