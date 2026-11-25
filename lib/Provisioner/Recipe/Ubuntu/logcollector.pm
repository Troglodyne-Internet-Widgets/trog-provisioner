package Provisioner::Recipe::Ubuntu::logcollector;

#ABSTRACT: What logcollector needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::logcollector};

=head1 NAME

Provisioner::Recipe::Ubuntu::logcollector - Ubuntu's C<deps> for L<Provisioner::Recipe::logcollector>.

=head1 DESCRIPTION

The image ships rsyslog today.  This recipe names it anyway, because the
collector needs rsyslog and must not depend on what the image happens to contain.

=cut

=head2 $recipe->deps()

C<rsyslog>.  See L</DESCRIPTION>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps { return qw{rsyslog} }

1;
