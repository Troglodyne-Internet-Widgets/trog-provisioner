package Provisioner::Recipe::Ubuntu::pdns;

#ABSTRACT: What pdns needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::pdns};

=head1 NAME

Provisioner::Recipe::Ubuntu::pdns - Ubuntu's C<deps> for L<Provisioner::Recipe::pdns>.

=head1 DESCRIPTION

A package name belongs to a distribution, not to the software, so the package
names are here.  The rest of pdns is in the recipe that this class inherits
from.

=cut

sub deps {
    return qw{pdns-server pdns-recursor pdns-tools pdns-backend-sqlite3 sqlite3 libconfig-simple-perl libnet-dns-perl libjson-perl python3-requests-unixsocket};
}

1;
