package Provisioner::Recipe::Ubuntu::autoupdate;

#ABSTRACT: What autoupdate needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::autoupdate};

=head1 NAME

Provisioner::Recipe::Ubuntu::autoupdate - Ubuntu's C<deps> for L<Provisioner::Recipe::autoupdate>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else autoupdate does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{};
}

1;
