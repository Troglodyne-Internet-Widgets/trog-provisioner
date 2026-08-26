package Provisioner::Recipe::nosnap;

#ABSTRACT: Rip snap out of the system root and branch.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 Provisioner::Recipe::nosnap

=head2 SYNOPSIS

    somedomain:
        nosnap:

=head2 DESCRIPTION

Rip out snap root and branch from the system, and disallow installation of anything requiring it.

For those of you who consider it an unacceptable risk to your deployed systems.

=cut

use parent qw{Provisioner::Recipe};

sub template_files {
    my ($self) = @_;

    return (
        'nosnap.tt' => 'nosnap.pref',
    );
}

sub tests {
    return qw{nosnap.tt};
}

1;
