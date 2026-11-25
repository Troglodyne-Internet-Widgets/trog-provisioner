package Provisioner::Recipe::Ubuntu::lynis;

#ABSTRACT: What Lynis needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::lynis};

=head1 NAME

Provisioner::Recipe::Ubuntu::lynis - Ubuntu's C<deps> for L<Provisioner::Recipe::lynis>.

=cut

=head2 @pkgs = $recipe->deps()

C<lynis>, from the archive that C<package_sources> names.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{lynis};
}

=head2 @sources = $recipe->package_sources()

The archive of CISOfy.  It has a newer C<lynis> than Ubuntu, so apt takes the
package from it with no pin.

Returns a list of HashRef, one per archive, as L<Provisioner::Packager::Deb/A
source> describes it.

    my @sources = $recipe->package_sources();

=cut

sub package_sources {
    return (
        {
            name        => 'cisofy-lynis',
            uri         => 'https://packages.cisofy.com/community/lynis/deb/',
            suites      => ['stable'],
            components  => ['main'],
            key         => 'https://packages.cisofy.com/keys/cisofy-software-public.key',
            fingerprint => '84FAA9983B24AEF24D6C87F1FEBB7D1812576482',
        },
    );
}

1;
