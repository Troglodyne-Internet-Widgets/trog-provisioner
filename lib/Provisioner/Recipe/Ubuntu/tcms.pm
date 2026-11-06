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

=head2 @pkgs = $recipe->deps(%opts)

git, which the fragment clones tCMS with, and the packages that tCMS
declares for the release of Ubuntu in C<distro_release>.  See
L<Provisioner::Recipe::tcms/THE SYSTEM PACKAGES>, which also says when it dies.

=cut

sub deps {
    my ( $self, %opts ) = @_;
    return ( 'git', @{ $self->declared_for( host(%opts), %opts )->{packages} } );
}

=head2 @sources = $recipe->package_sources(%opts)

The archives that tCMS declares for the same release, each with the
fingerprint of its key.

=cut

sub package_sources {
    my ( $self, %opts ) = @_;
    return @{ $self->declared_for( host(%opts), %opts )->{sources} };
}

1;
