package Provisioner::Recipe::Ubuntu::koan;

#ABSTRACT: What koan needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe::koan};

=head1 NAME

Provisioner::Recipe::Ubuntu::koan - Ubuntu's C<deps> for L<Provisioner::Recipe::koan>.

=head1 DESCRIPTION

A package name is a fact about a distribution rather than about the software, so
this is where it lives.  Everything else koan does is in the recipe this
inherits from.

=cut

sub deps {
    my @pkgs = qw{
      git
      python3
      python3-venv
      python3-pip
      python3-dev
      nodejs
      npm
      gh
      ca-certificates
      make
      build-essential
    };

    # libolm is only strictly required when messaging_provider=matrix
    # with E2EE on, but it's small and the host is single-purpose
    # always include so the pip install of matrix-nio[e2e] never
    # fails for want of a header.
    push @pkgs, qw{libolm-dev libffi-dev};
    return @pkgs;
}

1;
