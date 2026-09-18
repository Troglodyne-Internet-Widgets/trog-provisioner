package Provisioner::Recipe::Ubuntu::garage;

#ABSTRACT: What garage needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::garage};

=head1 NAME

Provisioner::Recipe::Ubuntu::garage - Ubuntu's C<deps> for L<Provisioner::Recipe::garage>.

=head2 @pkgs = $recipe->deps()

C<curl>, which downloads the garage binary, and C<liblmdb0>.

=cut

sub deps {
    return qw{curl liblmdb0};
}

1;
