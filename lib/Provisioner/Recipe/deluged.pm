package Provisioner::Recipe::deluged;

#ABSTRACT: Set up a Deluge seedbox with public HTTP downloads.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::deluged

=head2 SYNOPSIS

    somedomain:
        deluged:
            web_port: 8112
            ipv6: true

=head2 DESCRIPTION

Sets up a Deluge BitTorrent seedbox daemon, and serves the completed downloads
over public HTTP.

The vhost comes from C<nginxproxy>, which this recipe requires.  It serves the
completed downloads at C</torrents/> on the domain, with C<autoindex> on.  So a
person or a torrent app can browse the directory listings as an HTTP feed.  The
vhost sends every other request to the Deluge web UI on C<web_port>.

The recipe registers the BitTorrent listen ports (6881-6891) as a UFW
application profile.  If the C<ufw> recipe is also loaded, it opens these ports.

=head3 What survives a rebuild

C<remote_files> salvages C</var/lib/deluged/config/state/>.  C<restores> tells
the C<data> target to put it back before the daemon starts.  That directory
holds C<torrents.state> and the fastresume data next to it.  They are the list
of torrents that deluged seeds, and the progress of each one.  Without them, a
rebuilt seedbox starts idle, and nothing else on the machine knows what it did.

The recipe does not salvage the rest of the configuration directory, on purpose:

=over 4

=item * The recipe writes C<core.conf> from its own template on every new guest,
so a salvaged copy preserves nothing.

=item * The daemon generates the C<auth> file of credentials on first start, and
C<deluge-web> copies them into its own configuration.  If you restore only one
half of that pair, the web UI cannot talk to its daemon.  Two halves that are
generated together agree.

=back

A file that regenerates correctly does not belong in C<remote_files>.

The fetch reads the guest as root.  So the whole path down to C<state/> stays
C<debian-deluged:debian-deluged>, and no other account gets access to it.

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

=head2 $bool = $recipe->is_multi_tenant()

False.  There is one deluged and one F</var/lib/deluged/config/core.conf>, and
its download location is the directory of this domain.  A second domain points
the daemon at its own directory.  Then the client of the first domain writes to
a place that the first domain does not look.

=cut

sub is_multi_tenant { return 0 }

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
        # The torrent state only.  See "What survives a rebuild" above.
        '/var/lib/deluged/config/state/' => 'deluged/state/',
    );
}

sub tests {
    return qw{deluged.tt};
}

1;
