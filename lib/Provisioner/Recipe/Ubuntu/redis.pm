package Provisioner::Recipe::Ubuntu::redis;

#ABSTRACT: What redis needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::redis};

=head1 NAME

Provisioner::Recipe::Ubuntu::redis - Ubuntu's C<deps> for L<Provisioner::Recipe::redis>.

=cut

=head2 @pkgs = $recipe->deps()

C<redis-server>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{redis-server};
}

1;
