package Provisioner::Recipe::Ubuntu::nvm;

#ABSTRACT: What nvm needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::nvm};

=head1 NAME

Provisioner::Recipe::Ubuntu::nvm - Ubuntu's C<deps> for L<Provisioner::Recipe::nvm>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else nvm does is in the recipe this
inherits from.

=cut

sub deps {

    # libatomic1, because the node builds that nvm downloads link against
    # libatomic.so.1.  Ubuntu does not install it by default, and without it
    # node fails with "error while loading shared libraries".
    return qw{curl libatomic1};
}

1;
