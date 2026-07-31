package Provisioner::Recipe::garage;

use strict;
use warnings FATAL => 'all';

use parent qw{Provisioner::Recipe};

use HTTP::Tiny;
use JSON::PP;

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

=head3 deps

Requires C<curl> to download the Garage binary.

=head3 validate

Validates the recipe configuration:

=over 4

=item C<rpc_secret> (optional) — 64-character hex string used as the shared
RPC secret between cluster nodes.  Auto-generated with C<openssl rand -hex 32>
on first run and persisted to C<rpc_secret.txt> in the domain output directory.

=item C<version> (optional, default: latest GitHub release) — Garage release tag to download.

=item C<data_dir> (optional, default C</var/lib/garage/data>)

=item C<metadata_dir> (optional, default C</var/lib/garage/meta>)

=item C<replication_factor> (optional, default C<1>) — 1 for single-node.

=item C<s3_region> (optional, default C<garage>)

=item C<api_port> (optional, default C<3900>) — S3 API listen port.

=item C<rpc_port> (optional, default C<3901>) — Inter-node RPC port.

=item C<web_port> (optional, default C<3902>) — S3 static-web serve port.

=item C<admin_port> (optional, default C<3903>) — Admin API port.

=item C<zone> (optional, default C<dc1>) — Zone name for the layout assignment.

=item C<capacity> (optional, default C<1G>) — Storage capacity hint for layout.

=item C<nofile_limit> (optional, default C<65536>) — C<LimitNOFILE> value for the systemd unit.

=item C<buckets> (optional) — List of bucket names to create after startup.

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
    my $res = HTTP::Tiny->new( timeout => 10 )->get(
        'https://api.github.com/repos/deuxfleurs-org/garage/releases/latest',
        { headers => { 'Accept' => 'application/vnd.github+json' } },
    );
    if ( $res->{success} ) {
        my $data = eval { JSON::PP::decode_json( $res->{content} ) };
        return $data->{tag_name} if $data && $data->{tag_name};
    }
    warn "garage: could not fetch latest release version from GitHub, falling back to v1.0.1\n";
    return 'v1.0.1';
}

sub _rpc_secret {
    my ($self) = @_;
    my $secret_file = "$self->{output_dir}/rpc_secret.txt";
    if ( -f $secret_file ) {
        open( my $fh, '<', $secret_file ) or die "Cannot read $secret_file: $!";
        chomp( my $secret = <$fh> );
        return $secret;
    }
    my $secret = qx{openssl rand -hex 32};
    chomp $secret;
    die "openssl rand failed" unless $secret =~ /^[0-9a-f]{64}$/;
    open( my $fh, '>', $secret_file ) or die "Cannot write $secret_file: $!";
    print $fh "$secret\n";
    close $fh;
    chmod 0600, $secret_file;
    return $secret;
}

sub validate {
    my ( $self, %opts ) = @_;

    $opts{rpc_secret}         //= $self->_rpc_secret();
    $opts{version}            //= _latest_garage_version();
    $opts{data_dir}           //= '/var/lib/garage/data';
    $opts{metadata_dir}       //= '/var/lib/garage/meta';
    $opts{replication_factor} //= 1;
    $opts{s3_region}          //= 'garage';
    $opts{api_port}           //= 3900;
    $opts{rpc_port}           //= 3901;
    $opts{web_port}           //= 3902;
    $opts{admin_port}         //= 3903;
    $opts{zone}               //= 'dc1';
    $opts{capacity}           //= '1G';
    $opts{nofile_limit}       //= 65536;
    $opts{buckets}            //= [];

    $opts{buckets} = [ $opts{buckets} ]
        if $opts{buckets} && ref $opts{buckets} ne 'ARRAY';

    return %opts;
}

sub template_files {
    return (
        'garage.toml.tt'    => 'garage.toml',
        'garage.service.tt' => 'garage.service',
        'garage_init.sh.tt' => 'garage_init.sh',
    );
}

1;
