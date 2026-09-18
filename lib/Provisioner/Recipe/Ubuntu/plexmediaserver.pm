package Provisioner::Recipe::Ubuntu::plexmediaserver;

#ABSTRACT: What plexmediaserver needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::plexmediaserver};

=head1 NAME

Provisioner::Recipe::Ubuntu::plexmediaserver - Ubuntu's C<deps> for L<Provisioner::Recipe::plexmediaserver>.

=cut

sub deps {
    return qw{curl gnupg};
}

1;
