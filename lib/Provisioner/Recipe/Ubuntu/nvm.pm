package Provisioner::Recipe::Ubuntu::nvm;

#ABSTRACT: What nvm needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::nvm};

=head1 NAME

Provisioner::Recipe::Ubuntu::nvm - Ubuntu's C<deps> for L<Provisioner::Recipe::nvm>.

=cut

=head2 $recipe->deps()

C<curl>, and C<libatomic1>, because the builds of node that nvm downloads link
against it, and Ubuntu does not install it by default.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {

    # libatomic1, because the node builds that nvm downloads link against
    # libatomic.so.1.  Ubuntu does not install it by default, and without it
    # node fails with "error while loading shared libraries".
    return qw{curl libatomic1};
}

1;
