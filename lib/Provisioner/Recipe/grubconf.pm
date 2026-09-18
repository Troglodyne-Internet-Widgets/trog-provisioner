package Provisioner::Recipe::grubconf;

#ABSTRACT: Configure the grub kernel command line.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

Provisioner::Recipe::grubconf - set grub variables, such as the kernel command line.

=head1 SYNOPSIS

    grubconf:
        grub_vars:
            GRUB_CMDLINE_LINUX: "net.ifnames=0 ipv6.disable=1"

=head1 DESCRIPTION

Writes each key of C<grub_vars> as C<KEY="value"> to
F</etc/default/grub.d/00-grub.conf>, then runs C<update-grub>.  Use it to turn
off things such as the new names for network adapters, or IPv6.

=cut

use parent qw{Provisioner::Recipe};

sub args {
    return (
        type       => 'object',
        required   => [qw{grub_vars}],
        properties => {
            grub_vars => {
                type                 => 'object',
                minProperties        => 1,
                additionalProperties => { type => 'string' },
                description          => 'The variables to set in /etc/default/grub.d/00-grub.conf, by name.  Each value is written in double quotes.',
            },
        },
    );
}

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
