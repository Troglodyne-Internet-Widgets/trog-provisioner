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

The image ships rsyslog today.  This recipe names it anyway, because the shipper
needs rsyslog and must not depend on what the image happens to contain.

=cut

=head2 @pkgs = $recipe->deps()

C<rsyslog>.  See L</DESCRIPTION>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps { return qw{rsyslog} }

1;
