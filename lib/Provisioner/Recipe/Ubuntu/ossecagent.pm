package Provisioner::Recipe::Ubuntu::ossecagent;

#ABSTRACT: What the OSSEC agent needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::ossecagent};

use Provisioner::Cookbook();

=head1 NAME

Provisioner::Recipe::Ubuntu::ossecagent - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::ossecagent>.

=head1 DESCRIPTION

C<ossec-hids-agent> comes from the archive of Atomicorp, as the manager does.

=cut

=head2 @pkgs = $recipe->deps()

C<ossec-hids-agent>, and C<libxml-libxml-perl> for the ossec language of
configd.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{ossec-hids-agent libxml-libxml-perl};
}

=head2 @sources = $recipe->package_sources(%opts)

The archive of the manager, from L<Provisioner::Recipe::Ubuntu::ossec>.

=over 4

=item %opts - the configuration of the recipe for the domain, which the
manager reads its C<distro_release> from

=back

Returns a list of HashRef, one per archive, as L<Provisioner::Packager::Deb/A
source> describes it.  Dies as the manager does.

    my @sources = $recipe->package_sources( distro_release => 'noble' );

=cut

sub package_sources {
    my ( $self, %opts ) = @_;
    return Provisioner::Cookbook->load( 'ossec', distro => 'ubuntu' )->package_sources(%opts);
}

1;
