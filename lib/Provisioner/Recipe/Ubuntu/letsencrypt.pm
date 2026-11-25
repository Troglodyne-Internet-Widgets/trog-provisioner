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

=head2 @pkgs = $recipe->deps()

C<certbot> and C<dehydrated>, and C<ssl-cert> for its group, which owns each
private key.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{certbot dehydrated ssl-cert};
}

1;
