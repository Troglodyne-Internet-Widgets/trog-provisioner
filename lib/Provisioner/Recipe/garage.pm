package Provisioner::Recipe::garage;

#ABSTRACT: Install and configure the Garage S3-compatible object store.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Crypt::PRNG();

use parent qw{Provisioner::Recipe};

use HTTP::Tiny;
use Cpanel::JSON::XS();

# The version to use when the tag list cannot be read.  It must be a published
# release, because the guest dies on a 404 for any other version.
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

Installs and configures L<Garage|https://garagehq.deuxfleurs.fr/>, a small
S3-compatible object store that can run on many nodes.

The recipe downloads the statically linked garage binary from
garagehq.deuxfleurs.fr and installs a systemd service.  It writes
C</etc/garage.toml>.  It then runs C<garage_init.sh>, which applies a
single-node layout and makes the buckets that you name.  A cron job takes a
snapshot of the metadata every night.

The packages that garage needs come from the distribution subclass.  See
L<Provisioner::Recipe::Ubuntu::garage>.

=head3 Surviving a rebuild

A rebuild keeps the objects under C<data_dir> and the newest metadata snapshot.
The new node starts with its buckets and their contents, not as an empty
cluster with a new layout.  See C<remote_files> and C<restores> in
L<Provisioner::Recipe>.

C<data_dir> and C<metadata_dir> are C<garage:garage> 0750.  A restore does not
leave them owned by garage, so the fragment changes the owner back after it.
C<garage.service> sets C<UMask=0027>, which is narrower than the systemd
default.

Only the default paths are salvaged.  C<remote_files> does not get the domain
configuration.  If a node keeps its data in another place, the fetch finds
nothing, and you must add that path to the backup targets.  C<restores> gets
the configuration, so the restore uses the configured paths.

=cut

=head2 $version = Provisioner::Recipe::garage->latest_version()

The newest stable garage release, as its tag: C<v2.4.1>.

It reads the tag list on GitHub, not the releases, because that repository is
a mirror with no releases.  If GitHub does not answer, it warns and returns
C<$FALLBACK_VERSION>.  Without the warning, an older garage than you asked for
goes unnoticed.

The answer stays in C<$LATEST> until the process ends.  So every guest that
one run of C<bin/new_config> builds gets the same version from one request.

=cut

sub latest_version {
    return $LATEST //= _newest_stable_tag($TAGS) // do {
        warn "garage: could not read the release tags from $TAGS, falling back to $FALLBACK_VERSION
";
        $FALLBACK_VERSION;
    };
}

=head2 $tag = _newest_stable_tag($url)

Returns the first stable tag in the GitHub tag list at C<$url>.  The list is
newest first.  The list also holds C<-rc>, C<-beta> and C<-internal> tags, which
are skipped.  Returns undef if the list cannot be read.

=cut

sub _newest_stable_tag {
    my ($url) = @_;

    my $res = HTTP::Tiny->new( timeout => 10 )->get( $url, { headers => { 'Accept' => 'application/vnd.github+json' } } );
    return undef unless $res->{success};

    my $tags = eval { Cpanel::JSON::XS::decode_json( $res->{content} ) };
    foreach my $tag ( @{ ref $tags eq 'ARRAY' ? $tags : [] } ) {
        next unless ref $tag eq 'HASH' && defined $tag->{name};
        return $tag->{name} if $tag->{name} =~ m{\Av\d+[.]\d+[.]\d+\z};
    }
    return undef;
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain)

C</etc/garage.rpc_secret>, the 32-byte hex secret that the nodes of a cluster
use to authenticate to each other.  C<bin/provision> puts it on the guest from
the secret store, and C<rpc_secret_file> in C<garage.toml> names it.

So it is the same secret for every provision.  A new one is a rotation, and
the rest of the cluster stops talking to this node.  It is also never in the
domain directory, which goes into every backup.  See C<guest_secrets> in
L<Provisioner::Recipe>.

=cut

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

    # Defaulted here as well as in args, because required_recipes calls this
    # before validation, with only what the domain wrote.
    my $data     = $opts{data_dir}     // '/var/lib/garage/data';
    my $metadata = $opts{metadata_dir} // '/var/lib/garage/meta';

    return (
        $data                 => { from => "$install_dir/$domain/garage/data" },
        "$metadata/snapshots" => { from => "$install_dir/$domain/garage/snapshots" },
    );
}

sub rate_limits {

    # The ports that templates/files/ufw.garage.tt opens.
    return ( 3900 => 1024, 3901 => 1024, 3902 => 1024, 3903 => 1024 );
}

=head2 $bool = $recipe->is_multi_tenant()

False.  The endpoints this node answers on are one domain's: C<root_domain> is
C<.s3.E<lt>domainE<gt>> and C<.web.E<lt>domainE<gt>> in the single
F</etc/garage.toml> it reads.  A second domain would not be served beside the
first, it would take its place.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

The RPC secret is not configured here.  See C<guest_secrets>.

=over 4

=item C<version> (optional, default C<latest>)  The garage release tag to
download, or C<latest> for the newest stable one.  C<enrich> looks that up.

=item C<data_dir> (optional, default C</var/lib/garage/data>)

=item C<metadata_dir> (optional, default C</var/lib/garage/meta>)

=item C<replication_factor> (optional, default C<1>)  1 for a single node.

=item C<s3_region> (optional, default C<garage>)

=item C<api_port> (optional, default C<3900>)  The S3 API port.

=item C<rpc_port> (optional, default C<3901>)  The RPC port between nodes.

=item C<web_port> (optional, default C<3902>)  The S3 static web port.

=item C<admin_port> (optional, default C<3903>)  The admin API port.

=item C<zone> (optional, default C<dc1>)  The zone name for the layout.

=item C<capacity> (optional, default C<1G>)  The storage capacity for the layout.

=item C<nofile_limit> (optional, default C<65536>)  C<LimitNOFILE> for the systemd unit.

=item C<buckets> (optional)  The bucket names to make after garage starts.

=back

=cut

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

Changes a C<version> of C<latest> into the current release.  This is not in
C<args>, so C<bin/recipes>, C<bin/new_guest> and the tests can ask what this
recipe takes without a network request.

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

=head2 @commands = $recipe->remote_prepare($install_dir, $domain)

Returns C<garage-snapshot.sh>, which the guest runs before the fetch.  The
metadata says which object is which, so a rebuild needs a snapshot that matches
the objects fetched with it.  The nightly snapshot is older than they are.

=cut

sub remote_prepare {
    return ('/usr/local/sbin/garage-snapshot.sh');
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;

    # A snapshot, not the metadata itself, because a copy of a live LMDB
    # database has torn pages and restores as if it were good.
    #
    # In practice these are always the defaults.  bin/new_config builds the
    # object from the provisioner options only, and backupdestination calls
    # this on the class name.  See "Surviving a rebuild" above.
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

=head2 @hosts = $recipe->fetch_hosts()

C<garagehq.deuxfleurs.fr>, which serves garage's binaries.  Not
C<api.github.com>: the version is looked up by C<bin/new_config>, not by the
guest.

=cut

sub fetch_hosts {
    return ('garagehq.deuxfleurs.fr');
}

=head2 @classes = $recipe->cache_classes()

A published release is that release for good.  The tag list is not: it is what
says which release is current, and C<latest_version> reads it every build.

=cut

sub cache_classes {
    return (
        { class => 'immutable', pattern => 'garagehq\\.deuxfleurs\\.fr/_releases/' },
        { class => 'index',     pattern => 'api\\.github\\.com/' },
    );
}

1;
