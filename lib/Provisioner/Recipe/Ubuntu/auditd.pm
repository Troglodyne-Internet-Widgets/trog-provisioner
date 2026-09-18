package Provisioner::Recipe::Ubuntu::auditd;

#ABSTRACT: What auditd needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::auditd};

=head1 NAME

Provisioner::Recipe::Ubuntu::auditd - Ubuntu's C<deps> for L<Provisioner::Recipe::auditd>.

=cut

sub deps {
    return qw{auditd};
}

1;
