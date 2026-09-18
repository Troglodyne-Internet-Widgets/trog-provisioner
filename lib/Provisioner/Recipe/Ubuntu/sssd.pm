package Provisioner::Recipe::Ubuntu::sssd;

#ABSTRACT: What sssd needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::sssd};

=head1 NAME

Provisioner::Recipe::Ubuntu::sssd - Ubuntu's C<deps> for L<Provisioner::Recipe::sssd>.

=cut

sub deps {
    return qw{sssd sssd-ldap libpam-sss libnss-sss};
}

1;
