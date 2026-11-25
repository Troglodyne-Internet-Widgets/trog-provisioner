package Provisioner::Recipe::Ubuntu::nginxrelay;

#ABSTRACT: What the web relay needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::nginxrelay};

=head1 NAME

Provisioner::Recipe::Ubuntu::nginxrelay - Ubuntu's C<deps> for L<Provisioner::Recipe::nginxrelay>.

=cut

=head2 $recipe->deps()

The stream module of nginx, C<ipset>, and C<libdata-validate-domain-perl>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{libnginx-mod-stream ipset libdata-validate-domain-perl};
}

1;
