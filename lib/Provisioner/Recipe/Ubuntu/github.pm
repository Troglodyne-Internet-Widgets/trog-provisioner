package Provisioner::Recipe::Ubuntu::github;

#ABSTRACT: What github needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::github};

=head1 NAME

Provisioner::Recipe::Ubuntu::github - Ubuntu's C<deps> for L<Provisioner::Recipe::github>.

=head2 @pkgs = $recipe->deps()

The packages the fragment needs before it runs.  C<gh> is not among them: it
comes from GitHub's archive, which the global fragment adds.

=cut

sub deps {
    return qw{git curl ca-certificates openssh-client};
}

1;
