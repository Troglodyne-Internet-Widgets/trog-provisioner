package Provisioner::Recipe::Ubuntu::tpsgi;

#ABSTRACT: What tpsgi needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::tpsgi};

=head1 NAME

Provisioner::Recipe::Ubuntu::tpsgi - Ubuntu's C<deps> for L<Provisioner::Recipe::tpsgi>.

=head1 DESCRIPTION

A package name is a fact about a distribution, not about the software, so the
names are here.  The rest of tpsgi is in the recipe that this class inherits
from.

=cut

sub deps {
    return qw{git autotools-dev autoconf libseccomp-dev libtool libtool-bin};
}

1;
