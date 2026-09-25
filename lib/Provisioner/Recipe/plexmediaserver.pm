package Provisioner::Recipe::plexmediaserver;

#ABSTRACT: Install and configure Plex Media Server.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

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
Plex listens on port 32400 (TCP).  The C<ufw> recipe installs an application
profile for Plex, so the firewall lets clients connect.

The profile also opens the ports that Plex uses for local discovery:

=over 4

=item *

1900/udp is SSDP, which DLNA clients use to find the server.

=item *

32410, 32412, 32413 and 32414/udp are Plex GDM, which local servers and clients
use to find each other.

=item *

32469/udp is the DLNA server.

=back

Without these ports, a client can reach the server by its address but cannot
discover it.  People usually notice a broken media server this way.

=head3 deps

Returns the system packages that the recipe target needs before it runs.

=over 1

=item INPUTS: none

=item OUTPUTS: list of Debian package names

=back

=head3 remote_files

Salvages C</var/lib/plexmediaserver/>, which is the library.  The library holds
the metadata that Plex built when it scanned the media, the watch history of
each user and the playlists.  The media is on a mount and survives a rebuild
without help.  So the risk is that a rebuild loses what the library remembers.

The fragment restores the library before it starts Plex again.  First it removes
the directory skeleton that the package made.  It does this only when this
guest has nothing under C<Metadata>.  So a new provision of a running guest
keeps its own library, not the copy fetched off it minutes earlier.

A restored library brings its own C<Preferences.xml>.  So the fragment reads and
changes that file, and does not write a new one.  The MachineIdentifier and the
token that says the server is claimed stay as they are.  Only the certificate
path and the account settings change.  A rebuilt guest thus comes back to Plex as
the same server, not as a new one that waits for a claim.  Only a server that
was never linked needs C<claim_token>.

The fragment leaves the library owned by C<plex:plex>, and C<Preferences.xml>
too.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # SUPER adds the ufw dependency that rate_limits below asks for.  Without it,
    # this override drops the limits on 32400 and says nothing.
    return ( letsencrypt => sub { () }, $self->SUPER::required_recipes(%opts) );
}

sub rate_limits {

    # One client that streams opens a few connections.  A household opens a few
    # times that many.
    #
    # The discovery ports (1900, 32410/32412/32413/32414, 32469) are not here.
    # Discovery traffic is too small to need a limit.  The clients in a
    # household announce themselves from time to time and do not open
    # connections.
    return ( 32400 => 1024 );
}

=head2 @claims = $recipe->listens()

The ports that the Plex Media Server binds besides 32400, which
C<rate_limits> names: 32401 and 32600 on 127.0.0.1, and 1901, 32410 and 32412
to 32414, all UDP.  That is what it bound on a guest, which is not all that
its ufw profile opens: it bound neither 1900/udp nor 32469.

=cut

sub listens {
    return ( ( map { "127.0.0.1:$_" } 32401, 32600 ), map { "$_/udp" } 1901, 32410, 32412 .. 32414 );
}

sub args {
    return (
        required   => [qw{plex_login_name admin_mail}],
        properties => {
            plex_login_name => { type => 'string' },
            admin_mail      => { type => 'email' },
            media_dirs      => { type => 'array', items => { type => 'string' }, default => [] },

            # The fragment writes it into a sed expression in single quotes.
            claim_token => { type => 'string', pattern => '^claim-[A-Za-z0-9_-]+$', description => 'A token from https://plex.tv/claim that links a new server to the Plex account on its first start.  Only a server that has never been linked needs one.' },
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

=head2 @hosts = $recipe->fetch_hosts()

C<repo.plex.tv>, the apt repository that the package comes from.  The signing
key comes from C<downloads.plex.tv>, which F<bin/new_config> fetches, and the
guest does not.

=cut

sub fetch_hosts {
    return qw{repo.plex.tv};
}

=head2 @classes = $recipe->cache_classes()

The cache classes for the apt repository at C<repo.plex.tv>.  See C<apt_repo_classes>
in L<Provisioner::Recipe>.

=cut

sub cache_classes {
    my ($self) = @_;
    return $self->apt_repo_classes('repo.plex.tv');
}

1;
