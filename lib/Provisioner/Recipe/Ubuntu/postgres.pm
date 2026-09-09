package Provisioner::Recipe::Ubuntu::postgres;

#ABSTRACT: What postgres needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::postgres};

=head1 NAME

Provisioner::Recipe::Ubuntu::postgres - Ubuntu's C<deps> for L<Provisioner::Recipe::postgres>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else postgres does is in the recipe this
inherits from.

=cut

sub deps {

    # deps is the list cloud-init installs at first boot, so it can only
    # name Ubuntu packages: the PGDG repository is not added until the
    # global fragment runs, which installs the versioned server-dev package
    # from it.
    return qw{postgresql-common pigz};
}

1;
