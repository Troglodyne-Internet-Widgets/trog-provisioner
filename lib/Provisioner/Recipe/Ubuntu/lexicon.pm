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

A package name is a fact about a distribution, not about the software, so it is
here.  The recipe that this class inherits from does everything else that lexicon
does.

=cut

sub deps {
    return qw{lexicon};
}

1;
