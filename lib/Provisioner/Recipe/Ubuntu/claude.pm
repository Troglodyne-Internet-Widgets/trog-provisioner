package Provisioner::Recipe::Ubuntu::claude;

#ABSTRACT: What claude needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::claude};

=head1 NAME

Provisioner::Recipe::Ubuntu::claude - Ubuntu's C<deps> for L<Provisioner::Recipe::claude>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else claude does is in the recipe this
inherits from.

=cut

sub deps {

    # git and gh because this recipe writes a commit identity and seeds the
    # credential gh reads.  A credential for a client that is not installed is
    # inert, and the first guest built with one said so plainly: gh: command not
    # found.
    return qw{nodejs npm git gh};
}

1;
