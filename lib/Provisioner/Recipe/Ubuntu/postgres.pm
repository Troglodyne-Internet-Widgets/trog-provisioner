package Provisioner::Recipe::Ubuntu::postgres;

#ABSTRACT: What postgres needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::postgres};

=head1 NAME

Provisioner::Recipe::Ubuntu::postgres - Ubuntu's C<deps> for L<Provisioner::Recipe::postgres>.

=cut

sub deps {

    # cloud-init installs this list at first boot, before the PGDG repository
    # exists.  So it names only Ubuntu packages.  The global fragment adds PGDG
    # and installs the versioned packages from it.
    return qw{postgresql-common pigz};
}

1;
