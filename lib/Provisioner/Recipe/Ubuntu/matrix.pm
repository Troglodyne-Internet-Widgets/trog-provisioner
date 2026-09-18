package Provisioner::Recipe::Ubuntu::matrix;

#ABSTRACT: What matrix needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::matrix};

=head1 NAME

Provisioner::Recipe::Ubuntu::matrix - Ubuntu's C<deps> for L<Provisioner::Recipe::matrix>.

=head1 DESCRIPTION

A package name is a fact about the distribution, not about the software.  So
this module names the packages that matrix needs on Ubuntu.  The parent recipe
does everything else.

=head2 @pkgs = $recipe->deps()

The Python libraries of synapse, from the Ubuntu archive.  The synapse package
itself, C<matrix-synapse-py3>, comes from the matrix.org repository.  The
fragment installs it, because cloud-init installs these at first boot, before
that repository is configured.

=cut

sub deps {
    return qw{
      python3-cryptography
      python3-bcrypt
      python3-pil
      python3-twisted
      python3-yaml
      python3-jsonschema
      python3-netaddr
      python3-phonenumbers
      python3-prometheus-client
      python3-bleach
      python3-jinja2
      python3-sortedcontainers
      python3-treq
      python3-service-identity
      python3-signedjson
      python3-canonicaljson
      python3-attr
      python3-txacme
      python3-matrix-common
      python3-unpaddedbase64
      python3-pymacaroons
      python3-msgpack
    };
}

1;
