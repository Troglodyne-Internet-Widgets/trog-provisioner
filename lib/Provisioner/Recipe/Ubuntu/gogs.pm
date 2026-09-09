package Provisioner::Recipe::Ubuntu::gogs;

#ABSTRACT: What gogs needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::gogs};

=head1 NAME

Provisioner::Recipe::Ubuntu::gogs - Ubuntu's C<deps> for L<Provisioner::Recipe::gogs>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else gogs does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{git curl};
}

1;
