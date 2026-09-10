package Provisioner::Recipe::Ubuntu::roundcube;

#ABSTRACT: What roundcube needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::roundcube};

=head1 NAME

Provisioner::Recipe::Ubuntu::roundcube - Ubuntu's C<deps> for L<Provisioner::Recipe::roundcube>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else roundcube does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{
      dbconfig-common
      enchant-2
      libapr1t64
      libaprutil1-dbd-sqlite3
      libaprutil1-ldap
      libaprutil1t64
      libenchant-2-2
      php
      php-fpm
      php-auth-sasl
      php-common
      php-enchant
      php-gd
      php-intl
      php-mbstring
      php-sqlite3
      php-zip
      sqlite3
    };
}

1;
