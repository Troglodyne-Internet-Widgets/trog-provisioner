package Provisioner::Recipe::Ubuntu::pdns;

#ABSTRACT: What pdns needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::pdns};

=head1 NAME

Provisioner::Recipe::Ubuntu::pdns - Ubuntu's C<deps> for L<Provisioner::Recipe::pdns>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else pdns does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{pdns-server pdns-recursor pdns-tools pdns-backend-sqlite3 sqlite3 libconfig-simple-perl libnet-dns-perl libjson-perl python3-requests-unixsocket};
}

1;
