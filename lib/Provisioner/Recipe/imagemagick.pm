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

# The bindings are built against the perl the perl recipe installs under
# /opt/perl5.  Nothing said so, so on a guest that did not happen to have one
# build_imagick.sh ran everything against "/opt/perl5//bin/perl".
sub required_recipes {
    return ( perl => sub { () } );
}

sub args {
    return (
        type       => 'object',
        required   => [qw{version}],
        properties => {
            # TODO default to the latest imagemagick version available on github releases
            # A full release including the patch number, which is how the
            # archive names its tarballs: "7.1.0" is a 404, and without -f curl
            # saved the error page for tar to fall over.
            version => { type => 'string', pattern => '^[0-9]+[.][0-9]+[.][0-9]+-[0-9]+$' },
        },
    );
}

sub tests {
    return qw{imagemagick.tt};
}

1;
