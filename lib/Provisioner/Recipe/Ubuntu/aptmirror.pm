package Provisioner::Recipe::Ubuntu::aptmirror;

#ABSTRACT: What aptmirror needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::aptmirror};

=head1 NAME

Provisioner::Recipe::Ubuntu::aptmirror - Ubuntu's C<deps> for L<Provisioner::Recipe::aptmirror>.

=head1 DESCRIPTION

A package name belongs to a distribution, not to the software, so it lives
here.  The recipe that this module inherits from does everything else for
aptmirror.

=cut

sub deps { return qw{apt-mirror} }

1;
