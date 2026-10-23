package Provisioner::Recipe::Ubuntu::edge;

#ABSTRACT: What the edge needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::edge};

=head1 NAME

Provisioner::Recipe::Ubuntu::edge - Ubuntu's C<deps> for L<Provisioner::Recipe::edge>.

=cut

sub deps {
    return qw{libnginx-mod-stream ipset};
}

1;
