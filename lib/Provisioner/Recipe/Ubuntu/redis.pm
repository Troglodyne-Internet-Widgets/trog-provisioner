package Provisioner::Recipe::Ubuntu::redis;

#ABSTRACT: What redis needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::redis};

=head1 NAME

Provisioner::Recipe::Ubuntu::redis - Ubuntu's C<deps> for L<Provisioner::Recipe::redis>.

=head1 DESCRIPTION

A package name belongs to a distribution, not to the software, so it is here.
The parent recipe does everything else for redis.

=cut

sub deps {
    return qw{redis-server};
}

1;
