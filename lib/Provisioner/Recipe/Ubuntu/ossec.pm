package Provisioner::Recipe::Ubuntu::ossec;

#ABSTRACT: What the OSSEC manager needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::ossec};

=head1 NAME

Provisioner::Recipe::Ubuntu::ossec - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::ossec>.

=head1 DESCRIPTION

C<ossec-hids-server> comes from the archive of Atomicorp, which
C<package_sources> below names.  Ubuntu has no OSSEC.

=cut

=head2 @pkgs = $recipe->deps()

C<ossec-hids-server>, and C<libxml-libxml-perl> for the ossec language of
configd.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {

    # libxml-libxml-perl for the ossec language of configd, which reads
    # ossec.conf with XML::LibXML under the perl of the system.
    return qw{ossec-hids-server libxml-libxml-perl};
}

=head2 @sources = $recipe->package_sources(%opts)

The archive of Atomicorp, for C<distro_release>, the release of the domain.  The
key below signs the suites of noble and older.  The installer of Atomicorp names
a second key for the suites of Ubuntu 26 and later, so a later release needs
that key here.

=over 4

=item distro_release - Str|Undef - the release of the domain, such as
C<noble>; the pinned release when undef

=back

Returns a list of HashRef, one per archive, as L<Provisioner::Packager::Deb/A
source> describes it.  Dies when L<Provisioner::Recipe::ubuntu> does not know
C<distro_release>.

    my @sources = $recipe->package_sources( distro_release => 'noble' );

=cut

sub package_sources {
    my ( $self, %opts ) = @_;
    return (
        {
            name        => 'atomicorp',
            uri         => 'https://updates.atomicorp.com/channels/atomic/ubuntu',
            suites      => [ 'Provisioner::Recipe::ubuntu'->release_of( release => $opts{distro_release} ) ],
            components  => ['main'],
            key         => 'https://www.atomicorp.com/RPM-GPG-KEY.atomicorp.txt',
            fingerprint => '181866DF9DACA40E5B429B08FFBD5D0A4520AFA9',
        },
    );
}

1;
