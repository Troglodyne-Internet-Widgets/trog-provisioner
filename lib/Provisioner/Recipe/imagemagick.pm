package Provisioner::Recipe::imagemagick;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::imagemagick

=head2 SYNOPSIS

    somedomain:
        imagemagick:
            version: 7.1.0-48

=head2 DESCRIPTION

Builds and installs ImageMagick from source with Perl bindings.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{ghostscript libjpeg-dev libpng-dev libtiff-dev liblzma-dev libxml2-dev libdjvulibre-dev libfreetype-dev libperl-dev libjxl-dev libtcmalloc-minimal4t64 g++ pkg-config};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    my $ver = $opts{version};
    die "Must define version in [imagemagick] section of recipes.yaml" unless $ver;

    return %opts;
}

1;
