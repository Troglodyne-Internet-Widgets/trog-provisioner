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

=head2 @hosts = $recipe->fetch_hosts()

C<download.imagemagick.org>, where F<scripts/build_imagick.sh> fetches the
source release.

=cut

sub fetch_hosts {
    return ('download.imagemagick.org');
}

=head2 @classes = $recipe->cache_classes()

A release tarball named by version, which the archive keeps until it prunes it
-- and once pruned, what the cache kept is the only copy left.

=cut

sub cache_classes {
    return ( { class => 'immutable', pattern => 'download\\.imagemagick\\.org/archive/releases/' } );
}

1;
