package Provisioner::Recipe::Ubuntu::aptmirror;

#ABSTRACT: What aptmirror needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::aptmirror};

=head1 NAME

Provisioner::Recipe::Ubuntu::aptmirror - Ubuntu's C<deps> for L<Provisioner::Recipe::aptmirror>.

=cut

sub deps { return qw{apt-mirror} }

1;
