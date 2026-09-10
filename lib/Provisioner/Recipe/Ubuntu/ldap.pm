package Provisioner::Recipe::Ubuntu::ldap;

#ABSTRACT: What ldap needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::ldap};

=head1 NAME

Provisioner::Recipe::Ubuntu::ldap - Ubuntu's C<deps> for L<Provisioner::Recipe::ldap>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else ldap does is in the recipe this
inherits from.

=cut

sub deps {

    # libldap2, not libldap-2.5-0: the soname is in the package name on
    # some distros and not on Ubuntu 24.04, where the archive has libldap2.
    return qw{slapd ldap-utils libldap2 ssl-cert};
}

1;
