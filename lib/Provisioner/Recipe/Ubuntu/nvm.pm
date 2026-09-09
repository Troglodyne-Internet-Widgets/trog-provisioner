package Provisioner::Recipe::Ubuntu::nvm;

#ABSTRACT: What nvm needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::nvm};

=head1 NAME

Provisioner::Recipe::Ubuntu::nvm - Ubuntu's C<deps> for L<Provisioner::Recipe::nvm>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else nvm does is in the recipe this
inherits from.

=cut

sub deps {

    # libatomic1 because the node builds nvm downloads link against
    # libatomic.so.1, which Ubuntu does not install by default.  Without it
    # node is present and unrunnable -- "error while loading shared
    # libraries" on every invocation -- and a test that only asks
    # `command -v node` sees a path and calls it installed.
    return qw{curl libatomic1};
}

1;
