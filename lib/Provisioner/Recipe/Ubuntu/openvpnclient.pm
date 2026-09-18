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

sub deps {

    # The certificates arrive by rsync over ssh, so it needs both as well as openvpn.
    return qw{openvpn openssh-client rsync};
}

1;
