package Provisioner::Recipe::Ubuntu::openvpnclient;

#ABSTRACT: What openvpnclient needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::openvpnclient};

=head1 NAME

Provisioner::Recipe::Ubuntu::openvpnclient - Ubuntu's C<deps> for L<Provisioner::Recipe::openvpnclient>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else openvpnclient does is in the recipe this
inherits from.

=cut

sub deps {

    # It fetches its certificates over rsync, so it needs what does the
    # fetching as much as it needs openvpn.
    return qw{openvpn openssh-client rsync};
}

1;
