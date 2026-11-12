package Provisioner::Recipe::Ubuntu::loccount;

#ABSTRACT: What loccount needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::loccount};

=head1 NAME

Provisioner::Recipe::Ubuntu::loccount - Ubuntu's C<deps> for L<Provisioner::Recipe::loccount>.

=head2 @pkgs = $recipe->deps()

C<git>, which clones it, and C<make>, which runs its build.  C<python3> and
C<python3-ruamel.yaml>, because C<go generate> runs F<tablegen.py>, which
needs ruamel.yaml to read F<languages.yaml>.  The DESCRIPTION of
L<Provisioner::Recipe::loccount> says why.

=cut

sub deps {
    return qw{git make python3 python3-ruamel.yaml};
}

1;
