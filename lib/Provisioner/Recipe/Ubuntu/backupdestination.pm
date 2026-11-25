package Provisioner::Recipe::Ubuntu::backupdestination;

#ABSTRACT: What backupdestination needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::backupdestination};

=head1 NAME

Provisioner::Recipe::Ubuntu::backupdestination - Ubuntu's C<deps> for L<Provisioner::Recipe::backupdestination>.

=cut

=head2 @pkgs = $recipe->deps()

C<rsync>, which receives the data, and C<openssh-server>, which it arrives
over.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{rsync openssh-server};
}

1;
