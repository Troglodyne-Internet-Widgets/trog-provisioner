package Provisioner::Recipe::Ubuntu::claude;

#ABSTRACT: What claude needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::claude};

=head1 NAME

Provisioner::Recipe::Ubuntu::claude - Ubuntu's C<deps> for L<Provisioner::Recipe::claude>.

=head1 DESCRIPTION

C<deps> returns the Ubuntu packages that claude needs.  A package name belongs to
a distribution, not to the software, so the names live in this class.  The
recipe that this class inherits from does everything else.

=cut

sub deps {
    return qw{nodejs npm};
}

1;
