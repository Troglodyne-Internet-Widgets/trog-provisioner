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

sub deps {
    return qw{plexmediaserver};
}

=head2 @sources = $recipe->apt_sources()

The archive of Plex at C<repo.plex.tv>, with the v2 signing key.  Plex retired
C<downloads.plex.tv/repos/deb>, where every path answers 403.  The v2 key is a
different key, not the old key at a new URL.

=cut

sub apt_sources {
    return {
        name       => 'plexmediaserver',
        uri        => 'https://repo.plex.tv/deb/',
        suites     => ['public'],
        components => ['main'],
        key        => 'https://downloads.plex.tv/plex-keys/PlexSign.v2.key',
    };
}

1;
