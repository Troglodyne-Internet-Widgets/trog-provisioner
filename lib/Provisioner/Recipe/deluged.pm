package Provisioner::Recipe::deluged;

use strict;
use warnings FATAL => 'all';

use List::Util qw{any};
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

#XXX probably won't work in isolation
sub required_recipes {
    return ( nginxproxy => sub { () } );
}

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{deluged deluge-web};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    die "This recipe requires the nginxproxy recipe to function"
        unless any { $_ eq 'nginxproxy' } @{ $opts{modules} };

    $opts{web_port} //= 8112;
    die "deluged.web_port must be a positive integer"
        unless $opts{web_port} =~ /^\d+$/ && $opts{web_port} > 0;

    $opts{ipv6} //= 1;
    $opts{ipv6} = $opts{ipv6} ? 1 : 0;

    return %opts;
}

sub template_files {
    my ($self) = @_;
    return (
        'deluged.nginx.tt'    => 'deluged_nginx.conf',
        'deluged.core.conf.tt' => 'deluged_core.conf',
        'deluged.ufw.conf.tt'  => 'deluged_ufw.conf',
    );
}

sub tests {
    return qw{deluged.tt};
}

1;
