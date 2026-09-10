package Provisioner::Recipe::Ubuntu::cron;

#ABSTRACT: What cron needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::cron};

=head1 NAME

Provisioner::Recipe::Ubuntu::cron - Ubuntu's C<deps> for L<Provisioner::Recipe::cron>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else cron does is in the recipe this
inherits from.

=cut

sub deps {
    return qw{rkhunter sysstat cronie debsums};
}

1;
