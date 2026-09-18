package Provisioner::Recipe::Ubuntu::tcms;

#ABSTRACT: What tcms needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::tcms};

=head1 NAME

Provisioner::Recipe::Ubuntu::tcms - Ubuntu's C<deps> for L<Provisioner::Recipe::tcms>.

=cut

sub deps {
    return qw{sqlite3 libsqlite3-dev libmagic-dev git libxml2-dev libexpat1-dev libssl-dev zlib1g-dev g++ inkscape pkg-config libvirt-dev libpng-dev cmake};
}

1;
