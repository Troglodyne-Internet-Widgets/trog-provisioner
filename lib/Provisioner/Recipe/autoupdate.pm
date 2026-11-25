package Provisioner::Recipe::autoupdate;

#ABSTRACT: Automatically install updates from the package manager.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

my $ABSOLUTE_PATH = qr{\A / [^'\s]+ \z};

=head1 Provisioner::Recipe::autoupdate

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        autoupdate:
            autorestart: "/root/noautorestart"
            # Optional.  Reboot only from 02:00 up to 05:00.
            reboot_window:
                from: 2
                to: 5

=head2 DESCRIPTION

Installs the updates from the package manager every night at midnight.

If you set C<autorestart> to a path, the guest also reboots after an update that asks for a reboot.
It does not reboot while a file exists at that path.
If you do not set C<autorestart>, the guest never reboots itself.

With C<reboot_window>, the guest reboots only from the hour C<from> up to the
hour C<to>, in the time zone of the guest.  If C<to> is less than C<from>, the
window goes past midnight.  If the two are equal, every hour is in the window.

The recipe holds the reboot with a reboot check, which says why in the log:
C<held by /root/noautorestart>, or C<outside the reboot window 02:00-05:00>.
Other recipes hold it with checks of their own.  See Reboot checks in
L<Provisioner::Recipe>.

=head1 METHODS

=head2 %schema = $recipe->args()

The schema of the options: C<autorestart>, an absolute path, and
C<reboot_window>, an object of the hours C<from> and C<to>, from 0 to 23.
Neither is required.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        properties => {

            # A path, not a boolean: the reboot check reads it as a touchfile
            # that says "not now", and quotes it in single quotes.
            autorestart => {
                type        => 'string',
                pattern     => "$ABSOLUTE_PATH",
                description => 'Reboot after an update that asks for one, unless this path exists on the guest.  Unset installs no reboot cron, so the guest never restarts itself.',
            },
            reboot_window => {
                type        => 'object',
                required    => [qw{from to}],
                description => 'The hours when the guest can reboot itself, from the hour from up to the hour to.  Unset, it can reboot at any hour.  It has no effect without autorestart.',
                properties  => {
                    from => { type => 'integer', minimum => 0, maximum => 23, description => 'The first hour of the window.' },
                    to   => { type => 'integer', minimum => 0, maximum => 23, description => 'The hour when the window ends.' },
                },
            },
        },
    );
}

=head2 %files = $recipe->template_files()

The cron entry of the update, the cron entry of the reboot and the reboot
check, the same on every guest.

Returns a list of pairs, from each template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    return (
        'autoupdate.cron.tt'         => 'autoupdate_cron',
        'autorestart.cron.tt'        => 'autorestart_cron',
        'autoupdate.reboot-check.tt' => 'autoupdate.reboot-check',
    );
}

=head2 %required = $recipe->required_recipes(%opts)

C<cron>, which installs F<autoupdate_cron> as F</etc/cron.d/autoupdate>.  When
C<autorestart> is set, it also installs F<autorestart_cron> as
F</etc/cron.d/autorestart>.  The name has no domain in it, so a guest that
holds several domains runs F<reboot_if_needed> once.  The reboot check of each
domain is its own.

Returns the pair C<cron> and a code reference that returns the C<files> for
cron.

    my %required = $recipe->required_recipes( autorestart => '/root/noautorestart' );

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    my %files = ( autoupdate => 'autoupdate_cron' );
    $files{autorestart} = 'autorestart_cron' if $opts{autorestart};

    return ( cron => sub { return ( files => \%files ) } );
}

=head2 @tests = $recipe->tests()

Returns a list of the test templates that run on the guest: F<autoupdate.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{autoupdate.tt};
}

1;
