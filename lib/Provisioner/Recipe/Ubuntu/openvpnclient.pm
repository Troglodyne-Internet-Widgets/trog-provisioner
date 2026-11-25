package Provisioner::Recipe::Ubuntu::openvpnclient;

#ABSTRACT: What openvpnclient needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::openvpnclient};

=head1 NAME

Provisioner::Recipe::Ubuntu::openvpnclient - Ubuntu's C<deps> for L<Provisioner::Recipe::openvpnclient>.

=cut

=head2 @pkgs = $recipe->deps()

C<openvpn>, and C<openssh-client> and C<rsync>, because the certificates
arrive by rsync over ssh.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{openvpn openssh-client rsync};
}

1;
