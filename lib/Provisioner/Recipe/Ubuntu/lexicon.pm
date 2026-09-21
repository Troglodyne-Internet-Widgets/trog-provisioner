package Provisioner::Recipe::Ubuntu::lexicon;

#ABSTRACT: What lexicon needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::lexicon};

=head1 NAME

Provisioner::Recipe::Ubuntu::lexicon - Ubuntu's C<deps> for L<Provisioner::Recipe::lexicon>.

=cut

sub deps {

    # lexicon-pdns-af-unix.patch imports requests_unixsocket into a module the
    # CLI loads whichever provider it was asked for.
    return qw{lexicon python3-requests-unixsocket};
}

1;
