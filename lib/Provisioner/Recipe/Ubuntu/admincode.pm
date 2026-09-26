package Provisioner::Recipe::Ubuntu::admincode;

#ABSTRACT: What admincode needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::admincode};

=head1 NAME

Provisioner::Recipe::Ubuntu::admincode - Ubuntu's C<deps> for L<Provisioner::Recipe::admincode>.

=head2 @pkgs = $recipe->deps(%opts)

What the clone script needs, and the C<extra_pkgs> of the operator, which
cloud-init installs with the rest at first boot.

=cut

sub deps {
    my ( $self, %opts ) = @_;
    return ( qw{libpithub-perl libfile-pushd-perl git}, @{ $opts{extra_pkgs} // [] } );
}

1;
