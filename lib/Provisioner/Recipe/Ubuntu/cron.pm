package Provisioner::Recipe::Ubuntu::cron;

#ABSTRACT: What cron needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::cron};

=head1 NAME

Provisioner::Recipe::Ubuntu::cron - Ubuntu's C<deps> for L<Provisioner::Recipe::cron>.

=cut

sub deps {
    return qw{rkhunter sysstat cronie debsums};
}

1;
