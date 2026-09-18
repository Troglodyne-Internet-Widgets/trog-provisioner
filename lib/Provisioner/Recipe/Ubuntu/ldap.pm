package Provisioner::Recipe::Ubuntu::ldap;

#ABSTRACT: What ldap needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::ldap};

=head1 NAME

Provisioner::Recipe::Ubuntu::ldap - Ubuntu's C<deps> for L<Provisioner::Recipe::ldap>.

=cut

sub deps {

    # libldap2 is the name in the Ubuntu 24.04 archive.  ssl-cert is here for
    # its group, which slapd must be in to read the key in /etc/ssl/private.
    return qw{slapd ldap-utils libldap2 ssl-cert};
}

1;
