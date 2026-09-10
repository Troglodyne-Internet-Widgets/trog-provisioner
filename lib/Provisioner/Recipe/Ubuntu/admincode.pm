package Provisioner::Recipe::Ubuntu::admincode;

#ABSTRACT: What admincode needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::admincode};

=head1 NAME

Provisioner::Recipe::Ubuntu::admincode - Ubuntu's C<deps> for L<Provisioner::Recipe::admincode>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else admincode does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{libpithub-perl git};
}

1;
