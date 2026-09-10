package Provisioner::Recipe::Ubuntu::plexmediaserver;

#ABSTRACT: What plexmediaserver needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::plexmediaserver};

=head1 NAME

Provisioner::Recipe::Ubuntu::plexmediaserver - Ubuntu's C<deps> for L<Provisioner::Recipe::plexmediaserver>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else plexmediaserver does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{curl gnupg};
}

1;
