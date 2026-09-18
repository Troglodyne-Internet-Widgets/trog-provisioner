package Provisioner::Recipe::Ubuntu::trogrunner;

#ABSTRACT: What trogrunner needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::trogrunner};

=head1 NAME

Provisioner::Recipe::Ubuntu::trogrunner - Ubuntu's C<deps> for L<Provisioner::Recipe::trogrunner>.

=head1 DESCRIPTION

=head2 deps

Each of these lets a distribution from CPAN build.  A guest with a perl built
from source has no binary package to use instead.  So a missing header is a
failed C<cpanm> forty minutes into a provision, not an apt step that did
nothing.

=over 4

=item * C<libvirt-dev> and C<pkg-config> for C<Sys::Virt>.  This is the reason
a runner differs from any other guest.

=item * C<uuid-dev> for C<UUID>.  It links C<libuuid>.  Without the package,
the build fails at link time, and the error looks like a toolchain problem.

=item * C<libssl-dev> for C<Net::SSLeay>, C<libexpat1-dev> for C<XML::Parser>,
and C<libsqlite3-dev> for C<DBD::SQLite>.  The address pool is a SQLite
database.

=back

C<xorriso> is not here.  C<bin/preflight> asks for it on the hypervisor, which
is where the cloud-init seed is built.  C<rsync> and C<openssh-client> are
already in the base packages of every guest.

=cut

sub deps {
    return qw{
      build-essential
      pkg-config
      git
      libvirt-dev
      uuid-dev
      libssl-dev
      zlib1g-dev
      libexpat1-dev
      libsqlite3-dev
    };
}

1;
