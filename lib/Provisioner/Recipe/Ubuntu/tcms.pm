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

=cut

sub deps {

    # libtool, seccomp and autotools are all for inotify, which will move to tPSGI eventually
    return qw{sqlite3 libsqlite3-dev libmagic-dev git libxml2-dev libexpat1-dev libssl-dev zlib1g-dev g++ inkscape};
}

1;
