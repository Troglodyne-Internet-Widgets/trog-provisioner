package Provisioner::Recipe::Ubuntu::mariadb;

#ABSTRACT: What mariadb needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::mariadb};

=head1 NAME

Provisioner::Recipe::Ubuntu::mariadb - Ubuntu's C<deps> for L<Provisioner::Recipe::mariadb>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else mariadb does is in the recipe this
inherits from.

=cut

sub deps {

    # The mariadb packages are deliberately absent: cloud-init installs
    # deps before the makefile runs, so naming them here would install
    # Ubuntu's and leave the pin to downgrade them.  install_mariadb.sh
    # takes the set from the pinned repository instead.  pigz is the backup
    # script's.
    return qw{pigz};
}

1;
