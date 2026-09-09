package Provisioner::Recipe::Ubuntu::configd;

#ABSTRACT: What configd needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::configd};

=head1 NAME

Provisioner::Recipe::Ubuntu::configd - Ubuntu's C<deps> for L<Provisioner::Recipe::configd>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else configd does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{cpanminus make};
}

1;
