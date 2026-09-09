package Provisioner::Recipe::Ubuntu::openvpn;

#ABSTRACT: What openvpn needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::openvpn};

=head1 NAME

Provisioner::Recipe::Ubuntu::openvpn - Ubuntu's C<deps> for L<Provisioner::Recipe::openvpn>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else openvpn does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{openvpn easy-rsa};
}

1;
