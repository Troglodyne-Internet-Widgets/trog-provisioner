package Provisioner::Recipe::Ubuntu::logshipper;

#ABSTRACT: What logshipper needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::logshipper};

=head1 NAME

Provisioner::Recipe::Ubuntu::logshipper - Ubuntu's C<deps> for L<Provisioner::Recipe::logshipper>.

=head1 DESCRIPTION

A package name is a fact about a distribution and not about the software, so it
lives here.  Everything else that logshipper does is in the recipe that this
class inherits from.

The image ships rsyslog today.  This recipe names it anyway, because the shipper
needs rsyslog and must not depend on what the image happens to contain.

=cut

sub deps { return qw{rsyslog} }

1;
