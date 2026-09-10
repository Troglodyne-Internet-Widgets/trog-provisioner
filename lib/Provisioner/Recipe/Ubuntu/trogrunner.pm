package Provisioner::Recipe::Ubuntu::trogrunner;

#ABSTRACT: What trogrunner needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::trogrunner};

=head1 NAME

Provisioner::Recipe::Ubuntu::trogrunner - Ubuntu's C<deps> for L<Provisioner::Recipe::trogrunner>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else the recipe does is in the class this
inherits from.

These are all here to let something on CPAN build.  A guest running a
source-built perl has no binary package to fall back on for any of it, so a
missing header is a failed C<cpanm> forty minutes into a provision rather than
an apt that quietly did nothing.

=over 4

=item * C<libvirt-dev> and C<pkg-config> for C<Sys::Virt>, which is the whole
reason a runner is different from any other guest.

=item * C<uuid-dev> for C<UUID>.  It links C<libuuid>, so without it the
failure is at link time and reads as a toolchain problem rather than a missing
package.

=item * C<libssl-dev> for C<Net::SSLeay>, C<libexpat1-dev> for C<XML::Parser>,
C<libsqlite3-dev> for C<DBD::SQLite> -- the address pool is a SQLite database.

=back

C<xorriso> is deliberately not here: C<bin/preflight> asks that of the
hypervisor, which is where the cloud-init seed is actually built.  C<rsync> and
C<openssh-client> are already among the base packages every guest gets.

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
