package Provisioner::Recipe::Ubuntu::fail2ban;

#ABSTRACT: What fail2ban needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::fail2ban};

=head1 NAME

Provisioner::Recipe::Ubuntu::fail2ban - Ubuntu's C<deps> for L<Provisioner::Recipe::fail2ban>.

=cut

=head2 $recipe->deps()

C<fail2ban>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{fail2ban};
}

1;
