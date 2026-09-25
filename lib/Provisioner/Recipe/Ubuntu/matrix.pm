package Provisioner::Recipe::Ubuntu::matrix;

#ABSTRACT: What matrix needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::matrix};

use Provisioner::Recipe::ubuntu();    ## no critic (ProhibitUnusedImports) -- release() is called on it by its quoted name

=head1 NAME

Provisioner::Recipe::Ubuntu::matrix - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::matrix>.

=head2 @pkgs = $recipe->deps()

The synapse package, C<matrix-synapse-py3>, from the archive of matrix.org that
C<apt_sources> below names, and the Python libraries of synapse from Ubuntu.

=cut

sub deps {
    return qw{
      matrix-synapse-py3
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

=head2 @sources = $recipe->apt_sources()

The archive of matrix.org.  It has the synapse package and its keyring, and
nothing else.  The package carries its own Python dependencies, so
C<txredisapi>, which synapse uses for redis, is inside it.

=cut

sub apt_sources {
    return {
        name       => 'matrix-org',
        uri        => 'https://packages.matrix.org/debian',
        suites     => [ 'Provisioner::Recipe::ubuntu'->release() ],
        components => ['main'],
        key        => 'https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg',
    };
}

=head2 @lines = $recipe->debconf_selections(%opts)

The two questions that the package asks.  Without the answers, its install
stops at a prompt for the server name.  The unit that this recipe installs reads
only F<homeserver.yaml>, so the name here reaches nothing that runs.

=cut

sub debconf_selections {
    my ( $self, %opts ) = @_;
    return (
        "matrix-synapse-py3 matrix-synapse/server-name string $opts{server_name}",
        'matrix-synapse-py3 matrix-synapse/report-stats boolean false',
    );
}

1;
