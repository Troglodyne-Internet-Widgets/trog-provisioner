package Provisioner::Recipe::Ubuntu::postgres;

#ABSTRACT: What postgres needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use feature 'state';

use parent qw{Provisioner::Recipe::postgres};

use IO::Uncompress::Gunzip();
use List::Util();
use Provisioner::Packager::Deb();
use Provisioner::Recipe::ubuntu();    ## no critic (ProhibitUnusedImports) -- release() is called on it by its quoted name

=head1 NAME

Provisioner::Recipe::Ubuntu::postgres - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::postgres>.

=cut

# The suite of PGDG for a release of Ubuntu: the one named, or the pinned one.
my sub suite ($release) {
    return 'Provisioner::Recipe::ubuntu'->release_of( release => $release ) . '-pgdg';
}

=head2 $recipe->deps(%opts)

C<postgresql-common>, C<pigz>, and the server, the client, the server
development files and PL/Perl of the major version C<version>, or else of the
newest that C<newest_version> finds for C<distro_release>.

=over 4

=item version - Int|Undef - the major version of postgres, such as C<16>

=item distro_release - Str|Undef - the release of the domain, such as
C<noble>; the pinned release when undef

=back

Returns a list of Str, the names of the packages.

Dies as C<newest_version> does, when C<version> is not set.

    my @pkgs = $recipe->deps( version => 16, distro_release => 'noble' );

=cut

sub deps {
    my ( $self, %opts ) = @_;

    my $major = $opts{version} // $self->newest_version( $opts{distro_release} );
    return ( qw{postgresql-common pigz}, map { "$_-$major" } qw{postgresql postgresql-client postgresql-server-dev postgresql-plperl} );
}

=head2 $recipe->package_sources(%opts)

The apt repository of the PostgreSQL project, PGDG, for C<distro_release>, the
release of the domain.  Its packages carry the major version in their names, so
it needs no pin.

=over 4

=item distro_release - Str|Undef - the release of the domain, such as
C<noble>; the pinned release when undef

=back

Returns a HashRef, the archive, as L<Provisioner::Packager::Deb/A source>
describes it.  Dies when L<Provisioner::Recipe::ubuntu> does not know
C<distro_release>.

    my $source = $recipe->package_sources( distro_release => 'noble' );

=cut

sub package_sources {
    my ( $self, %opts ) = @_;
    return {
        name       => 'pgdg',
        uri        => 'https://apt.postgresql.org/pub/repos/apt',
        suites     => [ suite( $opts{distro_release} ) ],
        components => ['main'],
        key        => 'https://www.postgresql.org/media/keys/ACCC4CF8.asc',
    };
}

=head2 $recipe->newest_version($release)

The highest major version that PGDG publishes in C<main> for C<$release>, or
for the pinned release, read from its package index.  C<main> holds only
released versions.  PGDG puts a beta in a component of its own, such as C<19>.

Asked once for each release in each process.  Dies when the index cannot be
fetched, or names no server.

=over 4

=item release - Str|Undef - the release of Ubuntu, such as C<noble>

=back

Returns an Int, the major version.

    my $major = $recipe->newest_version('noble');

=cut

sub newest_version {
    my ( $self, $release ) = @_;

    my $suite = suite($release);
    state %major;
    return $major{$suite} //= do {
        my $url = "https://apt.postgresql.org/pub/repos/apt/dists/$suite/main/binary-amd64/Packages.gz";
        my $res = Provisioner::Packager::Deb::fetch($url);
        die "Could not read the package index of PGDG at $url to find its newest postgres: $res->{status} $res->{reason}\n"
          unless $res->{success};

        my $index;
        IO::Uncompress::Gunzip::gunzip( \$res->{content} => \$index )
          or die "The package index of PGDG at $url does not decompress: $IO::Uncompress::Gunzip::GunzipError\n";
        my $newest = List::Util::max( $index =~ m/^Package:[ ]postgresql-(\d+)$/mg );
        die "The package index of PGDG at $url names no postgres server.\n" unless $newest;
        $newest;
    };
}

1;
