package Provisioner::Recipe::Ubuntu::tcms;

#ABSTRACT: What tcms needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::tcms};

=head1 NAME

Provisioner::Recipe::Ubuntu::tcms - Ubuntu's C<deps> for L<Provisioner::Recipe::tcms>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else tcms does is in the recipe this
inherits from.

=head2 deps

Most of these let something the tCMS checkout needs build from CPAN into a
source-built perl, which has no binary package to fall back on:

=over 4

=item * C<libvirt-dev> and C<pkg-config> for C<Sys::Virt>, pinned to the libvirt
pkg-config reports.

=item * C<libpng-dev> for C<Imager::File::PNG>.

=item * C<cmake> for C<Alien::cmake3>, under C<Trog::TOTP>.  With a cmake 3 on
the path it uses that; without one it downloads cmake, and cmake.org has
answered that download with a 403.

=back

=cut

sub deps {

    # libtool, seccomp and autotools are all for inotify, which will move to tPSGI eventually
    return qw{sqlite3 libsqlite3-dev libmagic-dev git libxml2-dev libexpat1-dev libssl-dev zlib1g-dev g++ inkscape pkg-config libvirt-dev libpng-dev cmake};
}

1;
