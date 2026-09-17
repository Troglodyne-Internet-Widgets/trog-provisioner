package Provisioner::Recipe::autoupdate;

#ABSTRACT: Automatically install updates from the package manager.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::autoupdate

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        autoupdate:
            autorestart: "/root/noautorestart"

=head2 DESCRIPTION

Automatically install updates from the package manager.

Optionally autorestart when this updates the kernel, unless the specified touchfile is present.

=cut

sub args {
    return (
        type       => 'object',
        properties => {

            # A path rather than a boolean, because the guest asks whether it is
            # a good moment: reboot_if_needed takes this as the touchfile that
            # says not now.  Unset installs no reboot cron at all, which is what
            # a guest that should never reboot itself wants.
            autorestart => {
                type        => 'string',
                description => 'Reboot after an update that asks for one, unless this path exists on the guest.  Unset installs no reboot cron, so the guest never restarts itself.',
            },
        },
    );
}

sub template_files {
    return (
        'autoupdate.cron.tt'  => 'autoupdate_cron',
        'autorestart.cron.tt' => 'autorestart_cron',
    );
}

sub tests {
    return qw{autoupdate.tt};
}

1;
