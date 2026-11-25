package Provisioner::Recipe::Ubuntu::deluged;

#ABSTRACT: What deluged needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::deluged};

=head1 NAME

Provisioner::Recipe::Ubuntu::deluged - Ubuntu's C<deps> for L<Provisioner::Recipe::deluged>.

=cut

=head2 @pkgs = $recipe->deps()

C<deluged>, the daemon, and C<deluge-web>, its web interface.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{deluged deluge-web};
}

1;
