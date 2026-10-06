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

sub deps {
    my ( $self, %opts ) = @_;

    my $major = $opts{version} // $self->newest_version( $opts{distro_release} );
    return ( qw{postgresql-common pigz}, map { "$_-$major" } qw{postgresql postgresql-client postgresql-server-dev postgresql-plperl} );
}

=head2 @sources = $recipe->package_sources(%opts)

The apt repository of the PostgreSQL project, PGDG, for C<distro_release>, the
release of the domain.  Its packages carry the major version in their names, so
it needs no pin.

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

=head2 $major = $recipe->newest_version($release)

The highest major version that PGDG publishes in C<main> for C<$release>, or
for the pinned release, read from its package index.  C<main> holds only
released versions.  PGDG puts a beta in a component of its own, such as C<19>.

Asked once for each release in each process.  Dies when the index cannot be
fetched, or names no server.

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
