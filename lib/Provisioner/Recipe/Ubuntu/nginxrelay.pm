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

sub deps {
    return qw{libnginx-mod-stream ipset};
}

1;
