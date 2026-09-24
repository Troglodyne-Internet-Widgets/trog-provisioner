package Provisioner::Recipe::ntp;

#ABSTRACT: Install and configure chrony for NTP time synchronization.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::ntp

=head2 SYNOPSIS

    somedomain:
        ntp:

Or with your own time servers and step threshold:

    somedomain:
        ntp:
            servers:
                - 0.pool.ntp.org
                - 1.pool.ntp.org
                - 2.pool.ntp.org
                - 3.pool.ntp.org
            makestep: "1.0 3"

=head2 DESCRIPTION

Installs chrony and configures it to keep the clock in time with NTP servers.

By default, chrony uses C<ntp.ubuntu.com> and the four C<pool.ntp.org> pools.
To use your own time sources, give a C<servers> list.  Examples are a local
stratum-1 server with a GPS receiver, or a pool closer to your region.

C<makestep> tells chrony when it can step the clock instead of slewing it
slowly.  The default C<"1.0 3"> means: step the clock if the offset is more
than 1 second during the first 3 clock updates.

=cut

=head2 @claims = $recipe->listens()

The command port of chrony, 323/udp on 127.0.0.1 and on ::1.  chrony serves no time, so
nothing listens on 123.

=cut

sub listens {
    return qw{127.0.0.1:323/udp [::1]:323/udp};
}

sub args {
    return (
        type       => 'object',
        properties => {
            servers => {
                type     => 'array',
                minItems => 1,
                items    => { type => 'string' },
                default  => [
                    qw{
                      ntp.ubuntu.com
                      0.pool.ntp.org
                      1.pool.ntp.org
                      2.pool.ntp.org
                      3.pool.ntp.org
                    }
                ],
            },
            makestep => { type => 'string', default => '1.0 3' },
        },
    );
}

sub template_files {
    return (
        'ntp.chrony.conf.tt' => 'chrony.conf',

        # The ufw application profile that opens outbound 123/udp.
        # ntp.ufw.conf.tt says why it is a profile and not a rule.
        'ntp.ufw.conf.tt' => 'ntp_ufw.conf',
    );
}

sub tests {
    return qw{ntp.tt};
}

1;
