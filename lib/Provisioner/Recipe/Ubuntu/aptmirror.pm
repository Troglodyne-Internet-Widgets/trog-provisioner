package Provisioner::Recipe::Ubuntu::aptmirror;

#ABSTRACT: What aptmirror needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::aptmirror};

=head1 NAME

Provisioner::Recipe::Ubuntu::aptmirror - Ubuntu's C<deps> for L<Provisioner::Recipe::aptmirror>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else aptmirror does is in the recipe this
inherits from.

=cut

sub deps { return qw{apt-mirror} }

1;
