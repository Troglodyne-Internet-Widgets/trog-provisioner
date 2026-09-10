package Provisioner::Recipe::ntp;

#ABSTRACT: Install and configure chrony for NTP time synchronisation.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::ntp

=head2 SYNOPSIS

    somedomain:
        ntp:

Or with custom time servers and step threshold:

    somedomain:
        ntp:
            servers:
                - 0.pool.ntp.org
                - 1.pool.ntp.org
                - 2.pool.ntp.org
                - 3.pool.ntp.org
            makestep: "1.0 3"

=head2 DESCRIPTION

Installs and configures chrony for NTP time synchronisation.

By default uses the Debian/Ubuntu vendor NTP pools.  Override with
a C<servers> list if you want to use your own NTP sources (e.g. local
GPS-disciplined stratum-1, or a pool closer to your region).

C<makestep> controls when chrony is allowed to step the clock rather
than slowly slew it.  The default C<"1.0 3"> means: step if the
offset exceeds 1 second during the first 3 clock updates.

=cut

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

        # The ufw application profile that opens outbound 123/udp.  A bare
        # `ufw allow` in the fragment does not survive the `ufw reset` that
        # setup-ufw-rules opens with, and the ufw target runs after this
        # one.
        'ntp.ufw.conf.tt' => 'ntp_ufw.conf',
    );
}

sub tests {
    return qw{ntp.tt};
}

1;
