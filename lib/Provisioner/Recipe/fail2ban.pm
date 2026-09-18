package Provisioner::Recipe::fail2ban;

#ABSTRACT: Set up fail2ban rules for the configured recipes.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::fail2ban

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        fail2ban:

=head2 DESCRIPTION

Sets up a fail2ban jail for the domain.  The jail watches the tpsgi log of the
domain, and bans a host that gets too many 4xx responses as an anonymous user.
No other recipe gets a jail.

=cut

sub template_files {
    my ($self) = @_;

    return (
        'fail2ban.jail.tt'   => 'jail.cfg',
        'fail2ban.filter.tt' => 'filter.cfg',
    );
}

sub tests {
    return qw{fail2ban.tt};
}

1;
