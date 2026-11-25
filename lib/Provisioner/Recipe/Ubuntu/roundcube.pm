package Provisioner::Recipe::Ubuntu::roundcube;

#ABSTRACT: What roundcube needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::roundcube};

=head1 NAME

Provisioner::Recipe::Ubuntu::roundcube - Ubuntu's C<deps> for L<Provisioner::Recipe::roundcube>.

=cut

=head2 $recipe->deps()

PHP with C<php-fpm> and the extensions that Roundcube uses, C<sqlite3> with
C<dbconfig-common>, and the libraries of spelling and of APR.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

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
