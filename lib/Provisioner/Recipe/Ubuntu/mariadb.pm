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

sub deps {

    # The backup script uses pigz.
    return qw{mariadb-server mariadb-client mariadb-backup libmariadb-dev libmariadb-dev-compat pigz};
}

=head2 @sources = $recipe->apt_sources(%opts)

The archive of MariaDB for C<version>, pinned above 1000.  The pin lets apt
install a version below the one in Ubuntu, which ships 10.11.14.  MariaDB
publishes an archive for a release only for the distributions that existed when
it made the release.  For example, 11.4.4 and 10.11.10 have noble, and 10.11.7
does not.  L<Provisioner::AptSources> asks for the suite, and says so.

=cut

sub apt_sources {
    my ( $self, %opts ) = @_;
    return {
        name          => 'mariadb',
        uri           => "https://archive.mariadb.org/mariadb-$opts{version}/repo/ubuntu",
        suites        => [ 'Provisioner::Recipe::ubuntu'->release() ],
        components    => ['main'],
        architectures => ['amd64'],
        key           => 'https://mariadb.org/mariadb_release_signing_key.pgp',
        pin           => { priority => 1001 },
    };
}

1;
