package Provisioner::Recipe::Ubuntu::cron;

#ABSTRACT: What cron needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::cron};

=head1 NAME

Provisioner::Recipe::Ubuntu::cron - Ubuntu's C<deps> for L<Provisioner::Recipe::cron>.

=head2 @pkgs = $recipe->deps(%opts)

sysstat, cronie and debsums, and rkhunter where no OSSEC manager reads the logs
of C<domain>.  Where one does, the agent of OSSEC runs rootcheck instead.  See
L<Provisioner::Recipe::cron/Where OSSEC watches the guest>.  Without a
C<domain>, the list has rkhunter.

=cut

sub deps {
    my ( $self, %opts ) = @_;
    my $watched = defined $opts{domain} && $self->ossec_watches( $opts{domain} );
    return ( ( $watched ? () : 'rkhunter' ), qw{sysstat cronie debsums} );
}

1;
