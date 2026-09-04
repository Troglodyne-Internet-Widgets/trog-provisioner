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

=cut

sub required_recipes {
    my ($self, %opts) = @_;
    my $port = $opts{web_port} // 8112;
    my $ipv6 = $opts{ipv6} // 1;
    return (
        nginxproxy  => sub {
            (
                vhosts => {
                    80  => { ssl_redirect => 1, ipv6 => 1 },
                    443 => {
                        ssl => 1,
                        proxy_uri => "http://127.0.0.1:$port",
                        public_dir => 'torrents',
                        ipv6 => $ipv6,
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

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/var/lib/deluged/config/' => 'deluged/config/',
    );
}

sub tests {
    return qw{deluged.tt};
}

1;
