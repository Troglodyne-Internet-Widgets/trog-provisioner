package Provisioner::Recipe::Ubuntu::edge;

#ABSTRACT: What the edge needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::edge};

=head1 NAME

Provisioner::Recipe::Ubuntu::edge - Ubuntu's C<deps> and C<dep_conflicts> for L<Provisioner::Recipe::edge>.

=cut

sub deps {
    return qw{libnginx-mod-stream ipset postfix dovecot-core libcryptx-perl postfix-policyd-spf-python opendkim opendmarc miltertest};
}

# The relay is postfix, which conflicts with the sendmail of every other guest.
sub dep_conflicts {
    return qw{sendmail};
}

1;
