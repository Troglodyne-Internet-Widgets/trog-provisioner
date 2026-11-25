package Provisioner::Recipe::Ubuntu::cron;

#ABSTRACT: What cron needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::cron};

=head1 NAME

Provisioner::Recipe::Ubuntu::cron - Ubuntu's C<deps> for L<Provisioner::Recipe::cron>.

=head2 $recipe->deps(%opts)

sysstat, cronie and debsums, and rkhunter where no OSSEC manager reads the logs
of C<domain>.  Where one does, the agent of OSSEC runs rootcheck instead.  See
L<Provisioner::Recipe::cron/Where OSSEC watches the guest>.  Without a
C<domain>, the list has rkhunter.

=over 4

=item domain - Str|Undef - the domain of the guest, such as C<test.test>

=back

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps( domain => 'test.test' );

=cut

sub deps {
    my ( $self, %opts ) = @_;
    my $watched = defined $opts{domain} && $self->ossec_watches( $opts{domain} );
    return ( ( $watched ? () : 'rkhunter' ), qw{sysstat cronie debsums} );
}

1;
