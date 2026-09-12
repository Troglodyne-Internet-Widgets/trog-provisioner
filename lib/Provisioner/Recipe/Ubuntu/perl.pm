package Provisioner::Recipe::Ubuntu::perl;

#ABSTRACT: What perl needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::perl};

=head1 NAME

Provisioner::Recipe::Ubuntu::perl - Ubuntu's C<deps> for L<Provisioner::Recipe::perl>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else perl does is in the recipe this
inherits from.

=cut

sub deps {

    # perlbrew brings gcc and libc6-dev, which is what building a perl takes.
    #
    # The other two are for what this recipe installs into that perl once it is
    # built: Dist::Zilla wants CPAN::Uploader, which wants LWP::Protocol::https,
    # IO::Socket::SSL and Net::SSLeay.  Net::SSLeay stops its configure with
    # "COULD NOT FIND LIBSSL HEADERS" without libssl-dev, and then links
    # -lssl -lcrypto -lz whatever its configure found, so ld stops with "cannot
    # find -lz" without zlib1g-dev -- zlib1g itself ships no .so for the linker
    # to resolve.  Both measured on a guest carrying this recipe and nothing
    # else, a hundred and twenty-four distributions in; every other guest had
    # the headers from tcms or trogrunner and never showed either.
    return qw{perlbrew libcarp-always-perl libssl-dev zlib1g-dev};
}

1;
