package Provisioner::Recipe::Ubuntu::fail2ban;

#ABSTRACT: What fail2ban needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::fail2ban};

=head1 NAME

Provisioner::Recipe::Ubuntu::fail2ban - Ubuntu's C<deps> for L<Provisioner::Recipe::fail2ban>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else fail2ban does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{fail2ban};
}

1;
