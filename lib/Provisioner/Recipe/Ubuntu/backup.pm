package Provisioner::Recipe::Ubuntu::backup;

#ABSTRACT: What backup needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::backup};

=head1 NAME

Provisioner::Recipe::Ubuntu::backup - Ubuntu's C<deps> for L<Provisioner::Recipe::backup>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else backup does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{rsync openssh-server};
}

1;
