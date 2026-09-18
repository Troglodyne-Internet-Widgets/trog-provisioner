package Provisioner::Recipe::imagemagick;

#ABSTRACT: Build and install ImageMagick with perl bindings from source.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::imagemagick

=head2 SYNOPSIS

    somedomain:
        imagemagick:
            version: 7.1.0-48

=head2 DESCRIPTION

Builds ImageMagick from source with its Perl bindings, and installs it.

=cut

=head2 %required = $recipe->required_recipes()

Returns C<perl>.  The bindings build against the perl that the perl recipe
installs under F</opt/perl5>.

=cut

sub required_recipes {
    return ( perl => sub { () } );
}

sub args {
    return (
        type       => 'object',
        required   => [qw{version}],
        properties => {

            # TODO default to the latest imagemagick version available on github releases
            # A full release with the patch number, because the archive names
            # its tarballs that way: "7.1.0" is a 404.
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

A release tarball named by version.  The archive keeps it until it prunes it.
After that, the copy in the cache is the only copy left.

=cut

sub cache_classes {
    return ( { class => 'immutable', pattern => 'download\\.imagemagick\\.org/archive/releases/' } );
}

1;
