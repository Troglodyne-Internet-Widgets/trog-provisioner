package Provisioner::Recipe::Ubuntu::letsencrypt;

#ABSTRACT: What letsencrypt needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::letsencrypt};

=head1 NAME

Provisioner::Recipe::Ubuntu::letsencrypt - Ubuntu's C<deps> for L<Provisioner::Recipe::letsencrypt>.

=cut

sub deps {

    # ssl-cert is here for its group, which owns each private key.
    return qw{certbot dehydrated ssl-cert};
}

1;
