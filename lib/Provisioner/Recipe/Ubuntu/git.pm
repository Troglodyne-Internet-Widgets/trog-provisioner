package Provisioner::Recipe::Ubuntu::git;

#ABSTRACT: What git needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::git};

=head1 NAME

Provisioner::Recipe::Ubuntu::git - Ubuntu's C<deps> for L<Provisioner::Recipe::git>.

=head2 @pkgs = $recipe->deps()

C<git> itself, and the ssh client it pushes over.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{git openssh-client};
}

1;
