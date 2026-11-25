package Provisioner::Recipe::Ubuntu::openvpn;

#ABSTRACT: What openvpn needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::openvpn};

=head1 NAME

Provisioner::Recipe::Ubuntu::openvpn - Ubuntu's C<deps> for L<Provisioner::Recipe::openvpn>.

=cut

=head2 $recipe->deps()

C<openvpn>, and C<easy-rsa>, which makes its certificates.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{openvpn easy-rsa};
}

1;
