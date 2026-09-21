package Provisioner::Recipe::Ubuntu::rust;

#ABSTRACT: What rust needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::rust};

=head1 NAME

Provisioner::Recipe::Ubuntu::rust - Ubuntu's C<deps> for L<Provisioner::Recipe::rust>.

=head2 @pkgs = $recipe->deps()

C<rustup>, which is the installer and not a toolchain, and the C toolchain it
links with.  rustc calls C<cc> to link every binary it builds, and depends on
neither.

=cut

sub deps {
    return qw{rustup build-essential};
}

1;
