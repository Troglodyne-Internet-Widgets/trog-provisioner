package Provisioner::Recipe::Ubuntu::tcms;

#ABSTRACT: What tcms needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::tcms};

use Provisioner::Recipe::ubuntu();    ## no critic (ProhibitUnusedImports) -- it is called by its quoted name

=head1 NAME

Provisioner::Recipe::Ubuntu::tcms - Ubuntu's C<deps> and archives for L<Provisioner::Recipe::tcms>.

=cut

# The guest, as Dist::Conformance resolves a declaration for it: the release
# of the domain, or the pinned one.
my sub host (%opts) {
    my $ubuntu   = 'Provisioner::Recipe::ubuntu';
    my $codename = $ubuntu->release_of( release => $opts{distro_release} );
    return { packager => $ubuntu->packager, distro => $ubuntu->distribution, release => $ubuntu->release_version($codename), codename => $codename };
}

=head2 $recipe->deps(%opts)

git, which the fragment clones tCMS with, and the packages that tCMS
declares for the release of Ubuntu in C<distro_release>.  See
L<Provisioner::Recipe::tcms/THE SYSTEM PACKAGES>, which also says when it dies.

=over 4

=item %opts - the configuration of the recipe for the domain, of which
C<distro_release>, C<repo_url> and C<repo_branch> count here

=back

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps( distro_release => 'noble' );

=cut

sub deps {
    my ( $self, %opts ) = @_;
    return ( 'git', @{ $self->declared_for( host(%opts), %opts )->{packages} } );
}

=head2 $recipe->package_sources(%opts)

The archives that tCMS declares for the same release, each with the
fingerprint of its key.

=over 4

=item %opts - as for C<deps>

=back

Returns a list of HashRef, one per archive, as L<Provisioner::Packager::Deb/A
source> describes it.  Dies as C<deps> does.

    my @sources = $recipe->package_sources( distro_release => 'noble' );

=cut

sub package_sources {
    my ( $self, %opts ) = @_;
    return @{ $self->declared_for( host(%opts), %opts )->{sources} };
}

1;
