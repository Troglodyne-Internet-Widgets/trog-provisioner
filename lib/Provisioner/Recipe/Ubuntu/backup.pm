package Provisioner::Recipe::Ubuntu::backup;

#ABSTRACT: What backup needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::backup};

=head1 NAME

Provisioner::Recipe::Ubuntu::backup - Ubuntu's C<deps> for L<Provisioner::Recipe::backup>.

=cut

=head2 $recipe->deps()

C<rsync>, which copies the data, and C<openssh-server>, which it copies over.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{rsync openssh-server};
}

1;
