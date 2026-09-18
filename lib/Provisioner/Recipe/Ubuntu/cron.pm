package Provisioner::Recipe::Ubuntu::cron;

#ABSTRACT: What cron needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::cron};

=head1 NAME

Provisioner::Recipe::Ubuntu::cron - Ubuntu's C<deps> for L<Provisioner::Recipe::cron>.

=head1 DESCRIPTION

A package name is a fact about the distribution, not about the software.  So
this module names the packages that cron needs on Ubuntu.  The parent recipe
does everything else.

=cut

sub deps {
    return qw{rkhunter sysstat cronie debsums};
}

1;
