package Provisioner::Recipe::Ubuntu::pdns;

#ABSTRACT: What pdns needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::pdns};

=head1 NAME

Provisioner::Recipe::Ubuntu::pdns - Ubuntu's C<deps> for L<Provisioner::Recipe::pdns>.

=cut

sub deps {
    return qw{pdns-server pdns-recursor pdns-tools pdns-backend-sqlite3 sqlite3 libconfig-simple-perl libnet-dns-perl libjson-perl};
}

1;
