package Provisioner::Recipe::fail2ban;

#ABSTRACT: Set up fail2ban rules for the configured recipes.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::fail2ban

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        fail2ban:

=head2 DESCRIPTION

Sets up some fail2ban rules for your configured recipes.

Currently very limited: it configures a jail for tpsgi and nothing else.

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
