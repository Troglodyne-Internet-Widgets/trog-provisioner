package Provisioner::Recipe::lynis;

#ABSTRACT: Audit the hardening of the guest with Lynis every day, and log the result.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

my $TEST_ID = qr/\A [[:upper:]\d]+ - \d+ (?: : [\w.-]+ )? \z/;

=head1 NAME

Provisioner::Recipe::lynis - audit the guest with Lynis, and send the findings to syslog.

=head1 SYNOPSIS

In recipes.yaml:

    somedomain:
        lynis:
            skip_tests:
                - SSH-7408

To audit every guest, put it in C<_base>.

=head1 DESCRIPTION

Lynis checks the configuration of a machine against a list of hardening
tests.  Each test has an id, such as C<SSH-7408>.  The result is a
hardening index from 0 to 100, a list of warnings, and a list of suggestions.

This recipe installs Lynis and runs F<scripts/lynis_audit> once after the
build and then every day.  The script writes the full report to
F</var/log/lynis-report.dat> and sends what it found to syslog with the tag
C<lynis>:

    hardening_index=67 warnings=3 suggestions=48
    warning KRNL-5830: Reboot of system is most likely needed
    suggestion PKGS-7394: Install package apt-show-versions for patch management purposes

The summary has the priority C<user.notice>, each warning C<user.warning>, and
each suggestion C<user.info>.  On a guest with
L<Provisioner::Recipe::logshipper>, the lines go to the collector, and the
syslog dashboard of L<Provisioner::Recipe::grafanasyslog> shows them under the
appname C<lynis>.  L<Provisioner::Recipe::grafanalynis> reads the numbers and
the tests out of these lines, and draws the audits of the fleet on a dashboard
of their own.  So a change to the form of a line is a change to that recipe.

The audit is of the machine, not of a domain, so all of the work is in the
global half.

=head2 The package comes from CISOfy

Ubuntu noble has Lynis 3.0.9, from August 2023.  CISOfy, who write Lynis,
publish the current release in an archive of their own, and
L<Provisioner::Recipe::Ubuntu::lynis> takes the package from there.  The guest
test fails on a 3.0, so a guest that got the package of Ubuntu does not pass.

=head1 METHODS

=head2 args()

The schema of the options: C<skip_tests>, a list of distinct Lynis test ids,
empty by default.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            skip_tests => {
                type        => 'array',
                default     => [],
                uniqueItems => 1,
                items       => { type => 'string', pattern => "$TEST_ID" },
                description => 'The ids of the Lynis tests that the audit leaves out, such as SSH-7408.  A test that checks several keys takes one key after a colon, such as KRNL-6000:net.ipv4.ip_forward, and still checks the others.  Use it for a finding that this fleet accepts on purpose.',
            },
        },
    );
}

=head2 template_files()

The profile of Lynis, F<lynis_custom.prf> from F<lynis.custom.prf.tt>, and the
cron file F<lynis_cron> from F<lynis.cron.tt>.  They are the same whichever
recipes are loaded, so it takes no list of recipes.

Returns a list of pairs, from each template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    return (
        'lynis.custom.prf.tt' => 'lynis_custom.prf',
        'lynis.cron.tt'       => 'lynis_cron',
    );
}

=head2 %required = $recipe->required_recipes(%opts)

C<cron>, which installs F<lynis_cron> as F</etc/cron.d/lynis>.

Returns the pair of C<cron> and a sub that returns its C<files> option.

    my %required = $recipe->required_recipes( domain => 'test.test' );

=cut

sub required_recipes {
    return ( cron => sub { return ( files => { lynis => 'lynis_cron' } ) } );
}

=head2 tests()

Returns a list of the test templates that run on the guest: F<lynis.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{lynis.tt};
}

1;
