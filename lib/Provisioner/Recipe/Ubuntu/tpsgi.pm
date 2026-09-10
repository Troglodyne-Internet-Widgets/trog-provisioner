package Provisioner::Recipe::Ubuntu::tpsgi;

#ABSTRACT: What tpsgi needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::tpsgi};

=head1 NAME

Provisioner::Recipe::Ubuntu::tpsgi - Ubuntu's C<deps> for L<Provisioner::Recipe::tpsgi>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else tpsgi does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{git autotools-dev autoconf libseccomp-dev libtool libtool-bin};
}

1;
