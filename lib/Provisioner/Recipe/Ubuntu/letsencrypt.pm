package Provisioner::Recipe::Ubuntu::letsencrypt;

#ABSTRACT: What letsencrypt needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::letsencrypt};

=head1 NAME

Provisioner::Recipe::Ubuntu::letsencrypt - Ubuntu's C<deps> for L<Provisioner::Recipe::letsencrypt>.

=head1 DESCRIPTION

A package name is a fact about a distribution, not about the software, so it
is here.  Everything else that letsencrypt does is in the recipe that this
class inherits from.

=cut

sub deps {
    return qw{certbot dehydrated};
}

1;
