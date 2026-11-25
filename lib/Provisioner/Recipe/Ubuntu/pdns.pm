package Provisioner::Recipe::Ubuntu::pdns;

#ABSTRACT: What pdns needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';
no autovivification;

use parent qw{Provisioner::Recipe::pdns};

use Provisioner::Recipe::ubuntu();    ## no critic (ProhibitUnusedImports) -- release() is called on it by its quoted name

=head1 NAME

Provisioner::Recipe::Ubuntu::pdns - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::pdns>.

=cut

=head2 @pkgs = $recipe->deps()

The authoritative server with its tools and its sqlite3 backend, the recursor,
C<sqlite3>, and C<libnet-dns-perl>, C<libjson-perl> and
C<libdata-validate-domain-perl>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{pdns-server pdns-recursor pdns-tools pdns-backend-sqlite3 sqlite3 libnet-dns-perl libjson-perl libdata-validate-domain-perl};
}

=head2 @sources = $recipe->package_sources(%opts)

The release train of the authoritative server that C<repo_branch> names, from
C<repo.powerdns.com>, for C<distro_release>, the release of the domain.  It pins C<pdns-*> above Ubuntu, as PowerDNS says to, so
the server and its backend come from one release.  The recursor is not in this
archive, and comes from Ubuntu.

=over 4

=item repo_branch - Str|Undef - the release train, such as C<auth-51>; the
default of C<args> when undef

=item distro_release - Str|Undef - the release of the domain, such as
C<noble>; the pinned release when undef

=back

Returns a HashRef, the archive, as L<Provisioner::Packager::Deb/A source>
describes it.  Dies when L<Provisioner::Recipe::ubuntu> does not know
C<distro_release>.

    my $source = $recipe->package_sources( repo_branch => 'auth-51', distro_release => 'noble' );

=cut

sub package_sources {
    my ( $self, %opts ) = @_;

    my %args   = $self->args;
    my $branch = $opts{repo_branch} // $args{properties}{repo_branch}{default};
    return {
        name       => 'powerdns',
        uri        => 'https://repo.powerdns.com/ubuntu',
        suites     => [ 'Provisioner::Recipe::ubuntu'->release_of( release => $opts{distro_release} ) . "-$branch" ],
        components => ['main'],
        key        => 'https://repo.powerdns.com/FD380FBB-pub.asc',
        pin        => { packages => 'pdns-*', priority => 600 },
    };
}

1;
