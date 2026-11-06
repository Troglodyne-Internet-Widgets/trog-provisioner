package Provisioner::Recipe::Ubuntu::clod;

#ABSTRACT: What clod needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::clod};

use Provisioner::Recipe::ubuntu();    ## no critic (ProhibitUnusedImports) -- packager() is called on it by its quoted name

=head1 NAME

Provisioner::Recipe::Ubuntu::clod - Ubuntu's C<deps> and packager for L<Provisioner::Recipe::clod>.

=head2 @pkgs = $recipe->deps()

git, which the bot runs for its mirrors and work trees, and sqlite3, which
C<remote_prepare> backs the database up with.

=cut

sub deps {
    return qw{git sqlite3};
}

=head2 $packager = $recipe->distro_packager()

The packager of L<Provisioner::Recipe::ubuntu>, whose packages the installer
of L<Provisioner::Recipe::clod/THE SYSTEM PACKAGES> installs.

=cut

sub distro_packager {
    return 'Provisioner::Recipe::ubuntu'->packager;
}

1;
