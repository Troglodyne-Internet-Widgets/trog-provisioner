package Provisioner::Recipe::garage;

#ABSTRACT: Install and configure the Garage S3-compatible object store.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use HTTP::Tiny;
use Cpanel::JSON::XS();

# Used when the tag list cannot be reached.  It has to be a version that is
# actually published, because a version that is not is a 404 on the guest
# halfway through the provision rather than an older garage.
our $FALLBACK_VERSION = 'v1.0.1';

=head1 Provisioner::Recipe::garage

=head2 SYNOPSIS

    somedomain:
        garage:
            version: v1.0.1
            data_dir: /var/lib/garage/data
            metadata_dir: /var/lib/garage/meta
            replication_factor: 1
            s3_region: garage
            api_port: 3900
            rpc_port: 3901
            web_port: 3902
            admin_port: 3903
            zone: dc1
            capacity: 1G
            buckets:
                - my-bucket
                - another-bucket

=head2 DESCRIPTION

Installs and configures L<Garage|https://garagehq.deuxfleurs.fr/>, a lightweight
S3-compatible distributed object-storage server.

Downloads the statically-linked garage binary from GitHub releases, installs a
systemd service, writes C</etc/garage.toml>, and runs C<garage_init.sh> to
apply a single-node layout and create any requested S3 buckets.

=head3 Surviving a rebuild

C<data_dir> and C<metadata_dir> are salvaged off a running guest and put back on
the one that replaces it, before garage is started, so a rebuilt node comes up
with its buckets and their contents rather than as an empty single-node cluster
with a fresh layout.

The fetch has no sudo, so both directories are owned C<garage> with the admin
user as their group and the setgid bit set, and C<garage.service> is given a
C<UMask> that leaves what garage writes readable to that group.  Left as
C<garage:garage> 0750 they came back as empty directories and said nothing about
it, which is the failure this arrangement buys off: the objects are readable
from here on by whoever holds the admin account, and travel into the data
directory and into whatever backup is taken of it.

Only the default paths are salvaged.  C<remote_files> is called without the
domain configuration, so a node told to keep its data somewhere else is fetched
from C</var/lib/garage> regardless -- which finds nothing rather than the wrong
thing, and wants naming in the backup targets by hand.  Restoring is not
affected; the fragment knows the configured paths and uses them.

=head3 deps

Requires C<curl> to download the Garage binary.

=head3 validate

Validates the recipe configuration:

=over 4

=item C<rpc_secret> (optional)  64-character hex string used as the shared
RPC secret between cluster nodes.  Auto-generated with C<openssl rand -hex 32>
on first run and persisted to C<rpc_secret.txt> in the domain output directory,
so that it stays the same across provisions -- see C<persisted_secret> in
L<Provisioner::Recipe>.

=item C<version> (optional, default: latest GitHub release)  Garage release tag to download.

=item C<data_dir> (optional, default C</var/lib/garage/data>)

=item C<metadata_dir> (optional, default C</var/lib/garage/meta>)

=item C<replication_factor> (optional, default C<1>)  1 for single-node.

=item C<s3_region> (optional, default C<garage>)

=item C<api_port> (optional, default C<3900>)  S3 API listen port.

=item C<rpc_port> (optional, default C<3901>)  Inter-node RPC port.

=item C<web_port> (optional, default C<3902>)  S3 static-web serve port.

=item C<admin_port> (optional, default C<3903>)  Admin API port.

=item C<zone> (optional, default C<dc1>)  Zone name for the layout assignment.

=item C<capacity> (optional, default C<1G>)  Storage capacity hint for layout.

=item C<nofile_limit> (optional, default C<65536>)  C<LimitNOFILE> value for the systemd unit.

=item C<buckets> (optional)  List of bucket names to create after startup.

=back

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{curl liblmdb0};
    }
    die "Unsupported packager";
}

sub _latest_garage_version {

    # Tags rather than releases: the GitHub repository is a mirror and has never
    # cut a release, so /releases/latest answers 404 every time and this fell
    # back to v1.0.1 on every run.
    my $res = HTTP::Tiny->new( timeout => 10 )->get(
        'https://api.github.com/repos/deuxfleurs-org/garage/tags',
        { headers => { 'Accept' => 'application/vnd.github+json' } },
    );
    if ( $res->{success} ) {
        my $tags = eval { Cpanel::JSON::XS::decode_json( $res->{content} ) };

        # Newest first, and only the stable ones: the tag list carries -rc,
        # -beta and -internal tags we do not want to put on a guest.
        foreach my $tag ( @{ $tags || [] } ) {
            next unless ref $tag eq 'HASH' && defined $tag->{name};
            return $tag->{name} if $tag->{name} =~ m{\Av[0-9]+[.][0-9]+[.][0-9]+\z};
        }
    }
    warn "garage: could not fetch latest release tag from GitHub, falling back to $FALLBACK_VERSION\n";
    return $FALLBACK_VERSION;
}

sub rate_limits {

    # S3 and admin, RPC between nodes, and the web endpoint.  These are the
    # ports templates/files/ufw.garage.tt opens.
    return ( 3900 => 1024, 3901 => 1024, 3902 => 1024, 3903 => 1024 );
}

sub args {
    my $self = shift;
    return (
        type       => 'object',
        properties => {
            rpc_secret         => { type => 'string',  default => $self->persisted_secret('rpc_secret.txt'), },
            version            => { type => 'string',  default => _latest_garage_version(), },
            data_dir           => { type => 'string',  default => '/var/lib/garage/data' },
            metadata_dir       => { type => 'string',  default => '/var/lib/garage/meta' },
            replication_factor => { type => 'integer', default => 1 },
            s3_region          => { type => 'string',  default => 'garage' },
            api_port           => { type => 'integer', default => 3900, minimum => 1024 },
            rpc_port           => { type => 'integer', default => 3901, minimum => 1024 },
            web_port           => { type => 'integer', default => 3902, minimum => 1024 },
            admin_port         => { type => 'integer', default => 3903, minimum => 1024 },
            zone               => { type => 'string',  default => 'dc1' },
            capacity           => { type => 'string',  default => '1G' },
            nofile_limit       => { type => 'integer', default => '65536' },
            buckets            => {
                type    => 'array',
                default => [],
                items   => { type => 'string' },
            },
        },
    );
}

sub template_files {
    return (
        'garage.toml.tt'    => 'garage.toml',
        'garage.service.tt' => 'garage.service',
        'garage_init.sh.tt' => 'garage_init.sh',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;

    # The objects and the metadata that says what they are, which together are
    # everything about a garage node that is not already in garage.toml.
    # templates/garage.tt is the other half: it gives both directories the admin
    # user as their group, because the fetch is an sftp session as that user
    # with no sudo and 0750 garage:garage comes back empty without complaining,
    # and it calls restore_state on each of them before garage is started.
    #
    # The defaults in practice, whatever the domain configured.  Nothing hands
    # this method the domain configuration: bin/new_config builds the recipe
    # object out of the provisioner options alone, and backupdestination calls
    # it on the class name, so there is no data_dir on $self to find.  An
    # operator who moved either directory therefore gets a fetch of a path that
    # is not there and a restore with nothing to do -- a rebuild that loses the
    # objects rather than one that corrupts them, and a path to name in the
    # backup targets by hand.
    my $data_dir     = ref($self) ? ( $self->{data_dir}     // '/var/lib/garage/data' ) : '/var/lib/garage/data';
    my $metadata_dir = ref($self) ? ( $self->{metadata_dir} // '/var/lib/garage/meta' ) : '/var/lib/garage/meta';
    return (
        "$data_dir/"     => 'garage/data/',
        "$metadata_dir/" => 'garage/meta/',
    );
}

sub tests {
    return qw{garage.tt};
}

1;
