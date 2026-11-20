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

sub deps {

    # libxml-libxml-perl for the ossec language of configd, which reads
    # ossec.conf with XML::LibXML under the perl of the system.
    return qw{ossec-hids-server libxml-libxml-perl};
}

=head2 @sources = $recipe->package_sources()

The archive of Atomicorp, for C<distro_release>, the release of the domain.  The
key below signs the suites of noble and older.  The installer of Atomicorp names
a second key for the suites of Ubuntu 26 and later, so a later release needs
that key here.

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
