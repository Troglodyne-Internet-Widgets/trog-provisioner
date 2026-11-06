package Provisioner::Recipe::Ubuntu::tcms;

#ABSTRACT: What tcms needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::tcms};

use Provisioner::Recipe::ubuntu();    ## no critic (ProhibitUnusedImports) -- packager() is called on it by its quoted name

=head1 NAME

Provisioner::Recipe::Ubuntu::tcms - Ubuntu's C<deps> for L<Provisioner::Recipe::tcms>.

=head2 @pkgs = $recipe->deps(%opts)

The packages that tCMS declares for the packager of
L<Provisioner::Recipe::ubuntu>.  See
L<Provisioner::Recipe::tcms/THE SYSTEM PACKAGES>, which also says when it dies.

=cut

sub deps {
    my ( $self, %opts ) = @_;
    return $self->declared_packages( 'Provisioner::Recipe::ubuntu'->packager, %opts );
}

1;
