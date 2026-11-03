package Provisioner::Recipe::Ubuntu::clod;

#ABSTRACT: What clod needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::clod};

=head1 NAME

Provisioner::Recipe::Ubuntu::clod - Ubuntu's C<deps> for L<Provisioner::Recipe::clod>.

=head2 @pkgs = $recipe->deps()

git, which the bot runs for its mirrors and work trees, and sqlite3, which
C<remote_prepare> backs the database up with.

=cut

sub deps {
    return qw{git sqlite3};
}

1;
