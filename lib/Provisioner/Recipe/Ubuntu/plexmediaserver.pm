package Provisioner::Recipe::Ubuntu::plexmediaserver;

#ABSTRACT: What plexmediaserver needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::plexmediaserver};

=head1 NAME

Provisioner::Recipe::Ubuntu::plexmediaserver - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::plexmediaserver>.

=cut

=head2 @pkgs = $recipe->deps()

C<plexmediaserver>, from the archive that C<package_sources> names.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{plexmediaserver};
}

=head2 @sources = $recipe->package_sources()

The archive of Plex at C<repo.plex.tv>, with the v2 signing key.  Plex retired
C<downloads.plex.tv/repos/deb>, where every path answers 403.  The v2 key is a
different key, not the old key at a new URL.

Returns a HashRef, the archive, as L<Provisioner::Packager::Deb/A source>
describes it.

    my $source = $recipe->package_sources();

=cut

sub package_sources {
    return {
        name       => 'plexmediaserver',
        uri        => 'https://repo.plex.tv/deb/',
        suites     => ['public'],
        components => ['main'],
        key        => 'https://downloads.plex.tv/plex-keys/PlexSign.v2.key',
    };
}

1;
