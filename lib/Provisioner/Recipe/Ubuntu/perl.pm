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
    # libssl-dev is for what this recipe installs into that perl once it is
    # built: Dist::Zilla wants CPAN::Uploader, which wants LWP::Protocol::https,
    # IO::Socket::SSL and Net::SSLeay -- and Net::SSLeay stops its configure with
    # "COULD NOT FIND LIBSSL HEADERS", a hundred and twenty-four distributions
    # in.  Measured on a guest carrying this recipe and nothing else; every other
    # guest had the headers from tcms or trogrunner and never showed it.
    return qw{perlbrew libcarp-always-perl libssl-dev};
}

1;
