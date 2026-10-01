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

Installs the updates from the package manager every night at midnight.

If you set C<autorestart> to a path, the guest also reboots after an update that asks for a reboot.
It does not reboot while a file exists at that path.
If you do not set C<autorestart>, the guest never reboots itself.

=cut

sub args {
    return (
        type       => 'object',
        properties => {

            # A path, not a boolean: reboot_if_needed reads it as a touchfile
            # that says "not now".
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

=head2 %required = $recipe->required_recipes(%opts)

C<cron>, which installs F<autoupdate_cron> as F</etc/cron.d/autoupdate>.  When
C<autorestart> is set, it also installs F<autorestart_cron> as
F</etc/cron.d/E<lt>domainE<gt>-autorestart>.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    my %files = ( autoupdate => 'autoupdate_cron' );
    $files{"$opts{domain}-autorestart"} = 'autorestart_cron' if $opts{autorestart};

    return ( cron => sub { return ( files => \%files ) } );
}

sub tests {
    return qw{autoupdate.tt};
}

1;
