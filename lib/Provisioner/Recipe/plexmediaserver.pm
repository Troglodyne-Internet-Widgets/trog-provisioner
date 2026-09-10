package Provisioner::Recipe::plexmediaserver;

#ABSTRACT: Install and configure Plex Media Server.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::plexmediaserver

=head2 SYNOPSIS

    somedomain:
        plexmediaserver:
            plex_login_name: myplexusername
            admin_mail: admin@somedomain.test
            media_dirs:
                - /mnt/media/movies
                - /mnt/media/tv
            claim_token: claim-XXXXXXXXXXXXXXXXXXXX  # optional

=head2 DESCRIPTION

Installs and configures Plex Media Server from the official Plex apt repository.
Plex listens on port 32400 (TCP). A UFW application profile is registered so
the firewall allows access, and also carries the ports Plex uses for local
discovery: 1900/udp (SSDP, for DLNA clients), 32410/32412/32413/32414/udp
(Plex GDM, local server/client discovery) and 32469/udp (the DLNA server).
Without them the server is reachable by address but not discoverable, which
is the more common way people actually notice a media server is broken.

=head3 deps

Returns system package dependencies needed before the recipe target runs.

=over 1

=item INPUTS: none

=item OUTPUTS: list of Debian package names

=back

=head3 remote_files

Salvages C</var/lib/plexmediaserver/>, which is the library: the metadata Plex
built by scanning, what everybody watched and how far into it they got, and the
playlists.  The media itself lives on a mount and survives a rebuild without
help, so what is actually at risk is everything the library remembered about it.

The fragment restores it before Plex is started again, having first cleared away
the directory skeleton the package laid down -- and only when this guest has
nothing under C<Metadata> of its own, so re-provisioning a guest that is still
running keeps the library it has rather than the copy fetched off it minutes
earlier.

A restored library brings its own C<Preferences.xml>, which is why the fragment
reads and modifies that file rather than writing a fresh one: the
MachineIdentifier and the token saying this server is already claimed stay where
they are, and only the certificate path and the configured account go over the
top.  A rebuilt guest therefore comes back as the same server to Plex rather
than as a new one waiting to be claimed, and C<claim_token> is wanted only by a
server that has never been linked at all.

The directory is left owned C<plex:>I<admin_user> at 0750, from when the fetch
ran as that user and a library Plex kept to itself came back empty without saying
so.  The fetch reads the guest as root now and no longer needs it; taking it out
is issue #98.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # SUPER carries the ufw dependency that rate_limits above asks for; without
    # it this override would quietly drop the limits on 32400.
    return ( letsencrypt => sub { () }, $self->SUPER::required_recipes(%opts) );
}

sub rate_limits {

    # One client streaming opens a handful; a household opens a few handfuls.
    #
    # The discovery ports (1900, 32410/32412/32413/32414, 32469) are not named
    # here: broadcast discovery is nowhere near the volume to want a limit, and
    # a household's clients announce themselves occasionally rather than by
    # opening connections.
    return ( 32400 => 1024 );
}

sub args {
    return (
        required   => [qw{plex_login_name admin_mail}],
        properties => {
            plex_login_name => { type => 'string' },
            admin_mail      => { type => 'email' },
            media_dirs      => { type => 'array', items => { type => 'string' }, default => [] },
        },
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/var/lib/plexmediaserver/' => 'plexmediaserver/',
    );
}

sub tests {
    return qw{plexmediaserver.tt};
}

1;
