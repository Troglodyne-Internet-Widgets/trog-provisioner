package Provisioner::Recipe::Ubuntu::perl;

#ABSTRACT: What perl needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::perl};

=head1 NAME

Provisioner::Recipe::Ubuntu::perl - Ubuntu's C<deps> for L<Provisioner::Recipe::perl>.

=cut

=head2 $recipe->deps()

C<perlbrew>, which brings the compiler that a perl build needs, the libraries
that F<scripts/cpan_install> needs on the system perl, and C<libssl-dev> and
C<zlib1g-dev>, without which Net::SSLeay does not build.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {

    # perlbrew brings gcc and libc6-dev, which a perl build needs.
    #
    # Net::SSLeay needs the other two, and Dist::Zilla needs Net::SSLeay through
    # CPAN::Uploader.  Without libssl-dev, its configure stops with "COULD NOT
    # FIND LIBSSL HEADERS".  Without zlib1g-dev, ld stops with "cannot find
    # -lz", because zlib1g ships no .so for the linker.
    #
    # scripts/cpan_install runs on the system perl, before anything is installed
    # from CPAN, and reads the output of dzil listdeps with Module::Runtime.
    return qw{perlbrew libcarp-always-perl libmodule-runtime-perl libssl-dev zlib1g-dev};
}

1;
