package Provisioner::Recipe::Ubuntu::perl;

#ABSTRACT: What perl needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::perl};

=head1 NAME

Provisioner::Recipe::Ubuntu::perl - Ubuntu's C<deps> for L<Provisioner::Recipe::perl>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else perl does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{perlbrew libcarp-always-perl};
}

1;
