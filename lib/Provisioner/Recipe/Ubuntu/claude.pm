package Provisioner::Recipe::Ubuntu::claude;

#ABSTRACT: What claude needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::claude};

=head1 NAME

Provisioner::Recipe::Ubuntu::claude - Ubuntu's C<deps> for L<Provisioner::Recipe::claude>.

=head2 @pkgs = $recipe->deps()

What npm needs, and what fetches the rtk release.  rtk itself is not here: it
comes from its own C<.deb>, which no Ubuntu component publishes.  C<acl> gives the
C<restricted_user> its way through the directory of the domain.

=cut

sub deps {
    return qw{nodejs npm curl ca-certificates acl};
}

1;
