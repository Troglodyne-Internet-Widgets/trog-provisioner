package Provisioner::Recipe::Ubuntu::tpsgi;

#ABSTRACT: What tpsgi needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::tpsgi};

=head1 NAME

Provisioner::Recipe::Ubuntu::tpsgi - Ubuntu's C<deps> for L<Provisioner::Recipe::tpsgi>.

=cut

sub deps {
    return qw{git autotools-dev autoconf libseccomp-dev libtool libtool-bin};
}

1;
