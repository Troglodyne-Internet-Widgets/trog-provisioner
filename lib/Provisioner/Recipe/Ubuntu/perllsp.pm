package Provisioner::Recipe::Ubuntu::perllsp;

#ABSTRACT: What perllsp needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::perllsp};

=head1 NAME

Provisioner::Recipe::Ubuntu::perllsp - Ubuntu's C<deps> for L<Provisioner::Recipe::perllsp>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else perllsp does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{nodejs npm vim};
}

1;
