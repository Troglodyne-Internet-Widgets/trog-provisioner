package Provisioner::Recipe::Ubuntu::sshfastlane;

#ABSTRACT: What sshfastlane needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::sshfastlane};

=head1 NAME

Provisioner::Recipe::Ubuntu::sshfastlane - Ubuntu's C<deps> for L<Provisioner::Recipe::sshfastlane>.

=cut

=head2 $recipe->deps()

C<openssh-server>, which runs the second sshd, and C<ipset>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{openssh-server ipset};
}

1;
