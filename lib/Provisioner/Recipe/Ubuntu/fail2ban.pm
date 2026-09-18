package Provisioner::Recipe::Ubuntu::fail2ban;

#ABSTRACT: What fail2ban needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::fail2ban};

=head1 NAME

Provisioner::Recipe::Ubuntu::fail2ban - Ubuntu's C<deps> for L<Provisioner::Recipe::fail2ban>.

=head1 DESCRIPTION

A package name belongs to the distribution, not to the software, so the package
names are here.  The recipe that this module inherits from does everything else
for fail2ban.

=cut

sub deps {
    return qw{fail2ban};
}

1;
