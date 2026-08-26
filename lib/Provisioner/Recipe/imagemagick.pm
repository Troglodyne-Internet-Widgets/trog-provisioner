package Provisioner::Recipe::imagemagick;

#ABSTRACT: Build and install ImageMagick with perl bindings from source.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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

sub args {
    return (
        type       => 'object',
        required   => [qw{version}],
        properties => {
            # TODO default to the latest imagemagick version available on github releases
            version => { type => 'string' },
        },
    );
}

sub tests {
    return qw{imagemagick.tt};
}

1;
