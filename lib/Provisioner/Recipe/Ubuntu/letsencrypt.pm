package Provisioner::Recipe::Ubuntu::letsencrypt;

#ABSTRACT: What letsencrypt needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::letsencrypt};

=head1 NAME

Provisioner::Recipe::Ubuntu::letsencrypt - Ubuntu's C<deps> for L<Provisioner::Recipe::letsencrypt>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else letsencrypt does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{certbot lexicon dehydrated};
}

1;
