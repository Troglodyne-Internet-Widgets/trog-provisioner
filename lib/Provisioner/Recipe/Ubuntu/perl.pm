package Provisioner::Recipe::Ubuntu::perl;

#ABSTRACT: What perl needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::perl};

=head1 NAME

Provisioner::Recipe::Ubuntu::perl - Ubuntu's C<deps> for L<Provisioner::Recipe::perl>.

=head1 DESCRIPTION

A package name is a fact about the distribution, not about the software, so
the package names live here.  Everything else is in the recipe that this one
inherits from.

=cut

sub deps {

    # perlbrew brings gcc and libc6-dev, which a perl build needs.
    #
    # Net::SSLeay needs the other two, and Dist::Zilla needs Net::SSLeay through
    # CPAN::Uploader.  Without libssl-dev, its configure stops with "COULD NOT
    # FIND LIBSSL HEADERS".  Without zlib1g-dev, ld stops with "cannot find
    # -lz", because zlib1g ships no .so for the linker.
    return qw{perlbrew libcarp-always-perl libssl-dev zlib1g-dev};
}

1;
