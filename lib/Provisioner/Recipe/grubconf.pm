package Provisioner::Recipe::grubconf;

use 5.041;

use strict;
use warnings FATAL => 'all';

=head1 Provisioner::Recipe::grubconf

=head2 SYNOPSIS

    grubconf:
        grub_vars:
            GRUB_CMDLINE_LINUX: "net.ifnames=0 ipv6.disable=1"

=head2 DESCRIPTION

Configure grub.

Useful for disabling sometimes-harmful things like new adapter names or ipv6.

=cut

use parent qw{Provisioner::Recipe};

sub template_files {
    my ($self) = @_;

    return (
        'grubconf.tt' => '00-grub.conf',
    );
}

sub tests {
    return qw{grubconf.tt};
}

1;
