package Provisioner::Recipe::Ubuntu::perllsp;

#ABSTRACT: What perllsp needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::perllsp};

=head1 NAME

Provisioner::Recipe::Ubuntu::perllsp - Ubuntu's C<deps> for L<Provisioner::Recipe::perllsp>.

=head1 DESCRIPTION

A package name belongs to the distribution, not to the software, so the package
names are here.  The recipe that this module inherits from does everything else
for perllsp.

=cut

sub deps {
    return qw{nodejs npm vim};
}

1;
