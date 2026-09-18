package Provisioner::Recipe::Ubuntu::mariadb;

#ABSTRACT: What mariadb needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::mariadb};

=head1 NAME

Provisioner::Recipe::Ubuntu::mariadb - Ubuntu's C<deps> for L<Provisioner::Recipe::mariadb>.

=cut

sub deps {

    # No mariadb packages here.  Cloud-init installs deps before the makefile
    # runs, so it installs the Ubuntu packages before the pin exists.
    # install_mariadb.sh installs them from the pinned repository.  The backup
    # script uses pigz.
    return qw{pigz};
}

1;
