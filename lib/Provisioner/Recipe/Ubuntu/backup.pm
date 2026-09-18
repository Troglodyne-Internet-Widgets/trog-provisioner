package Provisioner::Recipe::Ubuntu::backup;

#ABSTRACT: What backup needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::backup};

=head1 NAME

Provisioner::Recipe::Ubuntu::backup - Ubuntu's C<deps> for L<Provisioner::Recipe::backup>.

=cut

sub deps {
    return qw{rsync openssh-server};
}

1;
