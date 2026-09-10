package Provisioner::Recipe::Ubuntu::data;

#ABSTRACT: What data needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::data};

=head1 NAME

Provisioner::Recipe::Ubuntu::data - Ubuntu's C<deps> for L<Provisioner::Recipe::data>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else data does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{openssh-server openssh-client rsync};
}

1;
