package Provisioner::Recipe::Ubuntu::garage;

#ABSTRACT: What garage needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::garage};

=head1 NAME

Provisioner::Recipe::Ubuntu::garage - Ubuntu's C<deps> for L<Provisioner::Recipe::garage>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else garage does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{curl liblmdb0};
}

1;
