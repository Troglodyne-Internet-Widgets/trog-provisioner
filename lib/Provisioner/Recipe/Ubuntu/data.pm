package Provisioner::Recipe::Ubuntu::data;

#ABSTRACT: What data needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::data};

=head1 NAME

Provisioner::Recipe::Ubuntu::data - Ubuntu's C<deps> for L<Provisioner::Recipe::data>.

=head1 DESCRIPTION

C<deps> returns the Ubuntu packages that data needs.  A package name belongs to
a distribution, not to the software, so the names live in this class.  The
recipe that this class inherits from does everything else.

=cut

sub deps {
    return qw{openssh-server openssh-client rsync};
}

1;
