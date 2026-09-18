package Provisioner::Recipe::Ubuntu::gogs;

#ABSTRACT: What gogs needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::gogs};

=head1 NAME

Provisioner::Recipe::Ubuntu::gogs - Ubuntu's C<deps> for L<Provisioner::Recipe::gogs>.

=head1 DESCRIPTION

A package name is a fact about the distribution, not about the software.  So
this module names the packages that gogs needs on Ubuntu.  The parent recipe
does everything else.

=head2 @pkgs = $recipe->deps()

C<git>, which gogs runs to serve repositories, and C<curl>, which the
fragment and the setup and mirror scripts use.

=cut

sub deps {
    return qw{git curl};
}

1;
