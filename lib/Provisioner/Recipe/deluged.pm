package Provisioner::Recipe::deluged;

#ABSTRACT: Set up a Deluge seedbox with public HTTP downloads.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::deluged

=head2 SYNOPSIS

    somedomain:
        deluged:
            web_port: 8112
            ipv6: true

=head2 DESCRIPTION

Sets up a Deluge bittorrent seedbox daemon and serves completed downloads
via nginx for public HTTP access at C<files.[domain]/torrents/>.

The nginx vhost uses C<autoindex> so directory listings are browsable and
work as an HTTP feed for torrent apps.  Deluge web UI runs on C<web_port>
and is proxied through the same nginx vhost at C</deluge/>.

The BitTorrent listen ports (6881-6891) are registered as a UFW application
profile so they are opened automatically when the C<ufw> recipe is also
loaded.

NOTE: Add C<files> to the C<aliases> section of ipmap.cfg for the domain
so that C<files.[domain]> is covered by the SSL certificate.

=head3 What survives a rebuild

C<remote_files> salvages C</var/lib/deluged/config/state/>, and the makefile
fragment puts it back before the daemon is started.  That directory is
C<torrents.state> and the fastresume data beside it: the list of what deluged is
meant to be seeding and how far through each one it got.  A rebuilt seedbox
without it comes up idle, and nothing else on the machine can say what it was
doing.

The rest of the config directory is left behind on purpose.  This recipe
rewrites C<core.conf> from its own template on every provision, so salvaging
that preserves nothing.  The C<auth> file is a set of daemon credentials
generated on first start which C<deluge-web> copies into its own config, and
restoring one half of that pair gives a web UI that cannot talk to the daemon it
is running against; generated fresh together they agree.  Something that
regenerates correctly does not belong in C<remote_files>.

The fetch is an sftp session as the admin user with no sudo, so the fragment
gives that user the group on the path down to C<state/>, 0750 on the directories
and 0640 on what is in them.  Salvaging the whole config directory, which is
what this recipe asked for before, could not work for the same reason: it is
owned C<debian-deluged:debian-deluged> throughout, so what came back was an
empty directory and no complaint about it.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    my $port = $opts{web_port} // 8112;
    my $ipv6 = $opts{ipv6}     // 1;
    return (
        nginxproxy => sub {
            (
                vhosts => {
                    80  => { ssl_redirect => 1, ipv6 => 1 },
                    443 => {
                        ssl        => 1,
                        proxy_uri  => "http://127.0.0.1:$port",
                        public_dir => 'torrents',
                        ipv6       => $ipv6,
                    },
                },
            )
        },
    );
}

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{deluged deluge-web};
    }
    die "Unsupported packager";
}

sub args {
    return (
        type       => 'object',
        properties => {
            web_port => { type => 'integer', minimum => 1024, default => 8112 },
            ipv6     => { type => 'boolean', default => 1 },
        },
    );
}

sub template_files {
    my ($self) = @_;
    return (
        'deluged.core.conf.tt' => 'deluged_core.conf',
        'deluged.ufw.conf.tt'  => 'deluged_ufw.conf',
    );
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};
    return ( '/var/lib/deluged/config/state' => { from => "$install_dir/$domain/deluged/state" } );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # The torrent state only.  The configuration around it is regenerated
        # every provision and the daemon credentials have to be, so this is the
        # whole of what a rebuild cannot make again for itself.
        '/var/lib/deluged/config/state/' => 'deluged/state/',
    );
}

sub tests {
    return qw{deluged.tt};
}

1;
