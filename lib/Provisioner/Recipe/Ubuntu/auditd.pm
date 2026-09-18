package Provisioner::Recipe::Ubuntu::auditd;

#ABSTRACT: What auditd needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::auditd};

=head1 NAME

Provisioner::Recipe::Ubuntu::auditd - Ubuntu's C<deps> for L<Provisioner::Recipe::auditd>.

=head1 DESCRIPTION

A package name belongs to a distribution, not to the software, so it lives
here.  The recipe that this module inherits from does everything else for
auditd.

=cut

sub deps {
    return qw{auditd};
}

1;
