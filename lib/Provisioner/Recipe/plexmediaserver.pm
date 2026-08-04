package Provisioner::Recipe::plexmediaserver;

use strict;
use warnings FATAL => 'all';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};

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
the firewall allows access.

=head3 deps

Returns system package dependencies needed before the recipe target runs.

=over 1

=item INPUTS: none

=item OUTPUTS: list of Debian package names

=back

=head3 validate

Validates and normalises configuration options.

=over 1

=item INPUTS: %opts hash with plexmediaserver configuration

=item OUTPUTS: processed %opts hash

=back

=head3 remote_files

Returns remote file mappings for backup/restore.

=over 1

=item INPUTS: $install_dir, $domain

=item OUTPUTS: hash of remote path => local backup path

=back

=cut

sub required_recipes {
    return ( letsencrypt => sub { () } );
}

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{curl gnupg};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    die "Must set plex_login_name in [plexmediaserver] section of recipes.yaml"
        unless $opts{plex_login_name};

    die "Must set admin_mail in [plexmediaserver] section of recipes.yaml"
        unless $opts{admin_mail};

    if ( $opts{media_dirs} ) {
        die "media_dirs must be an ARRAY" unless ref $opts{media_dirs} eq 'ARRAY';
    }
    $opts{media_dirs} //= [];

    return %opts;
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
