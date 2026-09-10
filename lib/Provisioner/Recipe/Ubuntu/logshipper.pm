package Provisioner::Recipe::Ubuntu::logshipper;

#ABSTRACT: What logshipper needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::logshipper};

=head1 NAME

Provisioner::Recipe::Ubuntu::logshipper - Ubuntu's C<deps> for L<Provisioner::Recipe::logshipper>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else logshipper does is in the recipe this
inherits from.

Named rather than assumed: the image ships rsyslog today, but this recipe is the
only reason it has to be there now that the distro recipe no longer configures
one.

=cut

sub deps { return qw{rsyslog} }

1;
