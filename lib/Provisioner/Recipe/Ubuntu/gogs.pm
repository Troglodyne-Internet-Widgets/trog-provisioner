package Provisioner::Recipe::Ubuntu::gogs;

#ABSTRACT: What gogs needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::gogs};

=head1 NAME

Provisioner::Recipe::Ubuntu::gogs - Ubuntu's C<deps> for L<Provisioner::Recipe::gogs>.

=head2 @pkgs = $recipe->deps()

C<git>, which gogs runs to serve repositories, and C<curl>, which the
fragment and the setup and mirror scripts use.

=cut

sub deps {
    return qw{git curl};
}

1;
