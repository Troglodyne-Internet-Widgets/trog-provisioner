package Provisioner::Recipe::Ubuntu::tpsgi;

#ABSTRACT: What tpsgi needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::tpsgi};

=head1 NAME

Provisioner::Recipe::Ubuntu::tpsgi - Ubuntu's C<deps> for L<Provisioner::Recipe::tpsgi>.

=cut

=head2 @pkgs = $recipe->deps()

C<git>, the autotools, C<libtool> and C<libseccomp-dev>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{git autotools-dev autoconf libseccomp-dev libtool libtool-bin};
}

1;
