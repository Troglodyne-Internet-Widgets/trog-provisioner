package Provisioner::Recipe::Ubuntu::koan;

#ABSTRACT: What koan needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::koan};

=head1 NAME

Provisioner::Recipe::Ubuntu::koan - Ubuntu's C<deps> for L<Provisioner::Recipe::koan>.

=head2 @pkgs = $recipe->deps()

Returns the Ubuntu packages that koan needs to build and run.

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

    # Only matrix with E2EE needs libolm, but it is small.  Always install it,
    # so that the pip install of matrix-nio[e2e] always finds its header.
    push @pkgs, qw{libolm-dev libffi-dev};
    return @pkgs;
}

1;
