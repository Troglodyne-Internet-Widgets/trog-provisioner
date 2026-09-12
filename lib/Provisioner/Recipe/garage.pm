package Provisioner::Recipe::garage;

#ABSTRACT: Install and configure the Garage S3-compatible object store.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use Crypt::PRNG();

use parent qw{Provisioner::Recipe};

use HTTP::Tiny;
use Cpanel::JSON::XS();

# Used when the tag list cannot be reached.  It has to be a version that is
# actually published, because a version that is not is a 404 on the guest
# halfway through the provision rather than an older garage.
our $FALLBACK_VERSION = 'v2.4.1';

# What latest_version found; see its POD.
our $LATEST;

my $TAGS = 'https://api.github.com/repos/deuxfleurs-org/garage/tags';

=head1 Provisioner::Recipe::garage

=head2 SYNOPSIS

    somedomain:
        garage:
            version: latest
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

Downloads the statically-linked garage binary from garagehq.deuxfleurs.fr,
installs a systemd service, writes C</etc/garage.toml>, and runs C<garage_init.sh> to
apply a single-node layout and create any requested S3 buckets.

=head3 Surviving a rebuild

C<data_dir> and C<metadata_dir> are salvaged off a running guest and put back on
the one that replaces it, before garage is started, so a rebuilt node comes up
with its buckets and their contents rather than as an empty single-node cluster
with a fresh layout.

Both directories are owned C<garage> with the admin user as their group and the
setgid bit set, and C<garage.service> is given a C<UMask> that leaves what garage
writes readable to that group.  The objects are therefore readable by whoever
holds the admin account, and travel into the data directory and into whatever
backup is taken of it.

B<That is no longer needed for the salvage.>  The fetch reads the guest as root
now.  Taking the widening out is issue #98.

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

=item The RPC secret

The 32-byte hex secret nodes in a cluster authenticate to each other with.  It
is not a configuration field: it is kept in the secret store, placed on the
guest as C</etc/garage.rpc_secret> by C<bin/provision>, and named to garage by
C<rpc_secret_file>.  So it is the same secret across provisions -- a fresh one
is a rotation, and the rest of the cluster stops talking to this node -- and it
never sits in the domain directory, which is what gets carried off to the
hypervisor and into every backup.  See C<guest_secrets> in
L<Provisioner::Recipe>.

=item C<version> (optional, default C<latest>)  Garage release tag to download,
or C<latest> for the newest stable one, which C<enrich> looks up -- see
C<latest_version> below.

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

=head2 $version = Provisioner::Recipe::garage->latest_version()

The newest stable garage release, as its tag: C<v2.4.1>.

Read out of GitHub's tag list rather than its releases, because the GitHub
repository is a mirror that has never cut one.  When GitHub does not answer it
is C<$FALLBACK_VERSION>, with a warning, since a garage older than intended is
otherwise silent.

Memoized for the life of the process in C<$LATEST>: every guest one
C<bin/new_config> run builds gets the same answer from one request.  Nothing
clears it but the process ending.

=cut

sub latest_version {
    return $LATEST //= _newest_stable_tag($TAGS) // do {
        warn "garage: could not read the release tags from $TAGS, falling back to $FALLBACK_VERSION
";
        $FALLBACK_VERSION;
    };
}

# The first stable tag in a GitHub tag list, which is newest first, or undef if
# there was no list to read.  Only the stable ones: the list carries -rc, -beta
# and -internal tags we do not want to put on a guest.
sub _newest_stable_tag {
    my ($url) = @_;

    my $res = HTTP::Tiny->new( timeout => 10 )->get( $url, { headers => { 'Accept' => 'application/vnd.github+json' } } );
    return undef unless $res->{success};

    my $tags = eval { Cpanel::JSON::XS::decode_json( $res->{content} ) };
    foreach my $tag ( @{ ref $tags eq 'ARRAY' ? $tags : [] } ) {
        next unless ref $tag eq 'HASH' && defined $tag->{name};
        return $tag->{name} if $tag->{name} =~ m{\Av[0-9]+[.][0-9]+[.][0-9]+\z};
    }
    return undef;
}

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    return (
        '/etc/garage.rpc_secret' => {
            ref      => "secret:garage/$domain-rpc-secret/password",
            generate => sub { Crypt::PRNG::random_bytes_hex(32) },
            owner    => 'garage:garage',
            mode     => '0600',
        },
    );
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # The objects as they are, and the metadata as a snapshot -- LMDB copied out
    # from under a running writer restores looking fine and is not, so
    # remote_prepare asks garage for one and this is what puts it back.
    # Defaulted here as well as in args, because required_recipes is asked before
    # anything is validated: what it sees is what the domain wrote, and a domain
    # that took the default wrote nothing at all.
    my $data     = $opts{data_dir}     // '/var/lib/garage/data';
    my $metadata = $opts{metadata_dir} // '/var/lib/garage/meta';

    return (
        $data                 => { from => "$install_dir/$domain/garage/data" },
        "$metadata/snapshots" => { from => "$install_dir/$domain/garage/snapshots" },
    );
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
            version            => { type => 'string',  default => 'latest', pattern => '\A(?:latest|v[0-9]+[.][0-9]+[.][0-9]+)\z' },
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

=head2 %opts = $recipe->enrich(%opts)

Turns a C<version> of C<latest> into the release it currently is.  Here rather than in C<args>, so that asking what this recipe
takes -- C<bin/recipes>, C<bin/new_guest>, a test -- never asks the internet.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{version} = $self->latest_version() if $opts{version} eq 'latest';

    return %opts;
}

sub template_files {
    return (
        'garage.toml.tt'          => 'garage.toml',
        'garage.service.tt'       => 'garage.service',
        'garage_init.sh.tt'       => 'garage_init.sh',
        'garage.snapshot.sh.tt'   => 'garage-snapshot.sh',
        'garage.snapshot.cron.tt' => 'garage-snapshot.cron',
    );
}

# A snapshot taken now, rather than whatever the nightly cron last left: the
# metadata is what says which object is which, and a rebuild wants the one that
# matches the objects coming down beside it.
sub remote_prepare {
    return ('/usr/local/sbin/garage-snapshot.sh');
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;

    # The objects, and a snapshot of the metadata that says what they are, which
    # together are everything about a garage node that is not already in
    # garage.toml.
    #
    # A snapshot rather than the metadata directory itself, because that is an
    # LMDB database: LMDB writes its files 0600 whatever the directory says, so
    # the group the rest of the tree is given never reaches them and the fetch
    # reads nothing -- and copying a live LMDB out from under a running writer
    # produces a database with a torn page in it that restores looking fine.
    # garage-snapshot.sh asks garage for one nightly; see garage.tt for the leg
    # that puts it back.
    # templates/garage.tt is the other half: it gives both directories the admin
    # user as their group -- which the fetch no longer needs, now that it reads
    # the guest as root; see issue #98 -- and it calls restore_state on each of
    # them before garage is started.
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
        "$data_dir/"               => 'garage/data/',
        "$metadata_dir/snapshots/" => 'garage/snapshots/',
    );
}

sub tests {
    return qw{garage.tt};
}

1;
