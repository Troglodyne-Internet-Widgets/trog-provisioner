package Provisioner::Recipe::Ubuntu::data;

#ABSTRACT: What data needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::data};

=head1 NAME

Provisioner::Recipe::Ubuntu::data - Ubuntu's C<deps> for L<Provisioner::Recipe::data>.

=cut

=head2 $recipe->deps()

C<openssh-server>, C<openssh-client> and C<rsync>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{openssh-server openssh-client rsync};
}

1;
