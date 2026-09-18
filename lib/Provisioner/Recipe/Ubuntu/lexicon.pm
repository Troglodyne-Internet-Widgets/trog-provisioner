package Provisioner::Recipe::Ubuntu::lexicon;

#ABSTRACT: What lexicon needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::lexicon};

=head1 NAME

Provisioner::Recipe::Ubuntu::lexicon - Ubuntu's C<deps> for L<Provisioner::Recipe::lexicon>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else lexicon does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{lexicon};
}

1;
