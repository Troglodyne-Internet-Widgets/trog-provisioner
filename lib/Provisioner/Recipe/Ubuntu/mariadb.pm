package Provisioner::Recipe::Ubuntu::mariadb;

#ABSTRACT: What mariadb needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::mariadb};

use Provisioner::Recipe::ubuntu();    ## no critic (ProhibitUnusedImports) -- release() is called on it by its quoted name

=head1 NAME

Provisioner::Recipe::Ubuntu::mariadb - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::mariadb>.

=cut

=head2 @pkgs = $recipe->deps()

The server, the client, C<mariadb-backup>, the client libraries for
development, and C<pigz>, which the backup script uses.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {

    # The backup script uses pigz.
    return qw{mariadb-server mariadb-client mariadb-backup libmariadb-dev libmariadb-dev-compat pigz};
}

=head2 @sources = $recipe->package_sources(%opts)

The archive of MariaDB for C<version> and C<distro_release>, pinned above 1000.
The pin lets apt install a version below the one in Ubuntu, which ships 10.11.14
in noble.  MariaDB publishes an archive for a release only for the
distributions that existed when it made the release.  For example, 11.4.4 and
10.11.10 have noble, and 10.11.7 does not.  For resolute, only 11.8.8 and later
and 12.3.2 and later have one, and no 10.11 or 11.4 release does.
L<Provisioner::Packager::Deb> asks for the suite, and says so.

=over 4

=item version - Str - the version of MariaDB, such as C<11.4.4>

=item distro_release - Str|Undef - the release of the domain, such as
C<noble>; the pinned release when undef

=back

Returns a HashRef, the archive, as L<Provisioner::Packager::Deb/A source>
describes it.  Dies when L<Provisioner::Recipe::ubuntu> does not know
C<distro_release>.

    my $source = $recipe->package_sources( version => '11.4.4', distro_release => 'noble' );

=cut

sub package_sources {
    my ( $self, %opts ) = @_;
    return {
        name          => 'mariadb',
        uri           => "https://archive.mariadb.org/mariadb-$opts{version}/repo/ubuntu",
        suites        => [ 'Provisioner::Recipe::ubuntu'->release_of( release => $opts{distro_release} ) ],
        components    => ['main'],
        architectures => ['amd64'],
        key           => 'https://mariadb.org/mariadb_release_signing_key.pgp',
        pin           => { priority => 1001 },
    };
}

1;
