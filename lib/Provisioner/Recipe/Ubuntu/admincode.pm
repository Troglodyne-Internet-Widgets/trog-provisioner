package Provisioner::Recipe::Ubuntu::admincode;

#ABSTRACT: What admincode needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::admincode};

use Provisioner::Recipe::ubuntu();    ## no critic (ProhibitUnusedImports) -- packager() is called on it by its quoted name

=head1 NAME

Provisioner::Recipe::Ubuntu::admincode - Ubuntu's C<deps> for L<Provisioner::Recipe::admincode>.

=head2 @pkgs = $recipe->deps(%opts)

What the clone script needs, and the C<extra_pkgs> of the operator, which
cloud-init installs with the rest at first boot.

=over 4

=item extra_pkgs - ArrayRef[Str]|Undef - the further packages of the operator

=back

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps( extra_pkgs => ['htop'] );

=cut

sub deps {
    my ( $self, %opts ) = @_;
    return ( qw{libpithub-perl libfile-pushd-perl git}, @{ $opts{extra_pkgs} // [] } );
}

=head2 $packager = $recipe->distro_packager()

The packager of L<Provisioner::Recipe::ubuntu>, which installs the system
packages that the smoke of L<Provisioner::Recipe::admincode> finds declared.

Returns a Str, such as C<deb>.

    my $packager = $recipe->distro_packager();

=cut

sub distro_packager {
    return 'Provisioner::Recipe::ubuntu'->packager;
}

1;
