package Provisioner::Recipe::Ubuntu::deluged;

#ABSTRACT: What deluged needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::deluged};

=head1 NAME

Provisioner::Recipe::Ubuntu::deluged - Ubuntu's C<deps> for L<Provisioner::Recipe::deluged>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else deluged does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{deluged deluge-web};
}

1;
