package Provisioner::Recipe::cron;

#ABSTRACT: Set up the root and service user crontabs.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Utils();

=head1 Provisioner::Recipe::cron

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        cron:
            from: foo@bar.baz
            user_scripts:
                - cmd: some_script.sh
                  interval: "5 0 * * *"
                  mailto: "whee@test.test"
            root_scripts:
                ...
            files:
                ldap-export: ldap-export.cron

If you do not want the output of a script, set its C<mailto> to C<none>.  If
you do not set C<mailto>, the output goes to the admin.

C<from> and each C<mailto> can be a local part alone or a whole address.  A
local part gets this domain appended.  An address does not change.

=head2 DESCRIPTION

Sets up the cron jobs of root, and the cron jobs of the service user.

C<from> sets MAILFROM, and defaults to C<cron>, so mail from a job comes from
C<cron@> the domain and not from the user that ran it.  Only cronie, which this
recipe installs, reads MAILFROM.  The C<cron> of Debian ignores it and sends as
the user.

C<files> installs files of the payload into F</etc/cron.d>.  Each key is the
name in F</etc/cron.d>, and its value is the file that a recipe generated.  A
recipe that runs jobs passes its files through C<required_recipes>, and the
depsolver merges what each recipe passes into one map.  Two recipes that give
one name different files are refused.  Each file gets C<MAILTO> and C<MAILFROM>
lines at the top, so its jobs mail the admin from C<from>, as the crontabs of
this recipe do.  So the template of such a file sets neither.

Debian's C<cron> also skips a file in F</etc/cron.d> whose name has a dot, such
as one named after the domain.  cronie runs it.

The cron jobs of root run:

    * SAR gathering
    * rkhunter
    * Log watchers (OOMs, SEGVs, root logins, new users, rsyslog drops,
      outgoing ufw blocks)
    * scan for writes to packaged files
    * dehydrated, if the domain uses the letsencrypt recipe

They also run each configured C<root_scripts> entry, from a PATH that starts
with C<script_dir>.  The service user runs each C<user_scripts> entry, from a
PATH that starts with the C<bin/> directory of the service install dir.

=cut

=head3 %opts = $recipe->enrich(%opts)

Sets what MAILFROM and each MAILTO say, and returns the options.

A local part in C<from> or C<mailto>, for example C<from: cron>, gets this
domain appended.  An address does not change, because a second domain gives
C<somebody@example.test@this.domain>.

C<mailto: none> becomes an empty MAILTO, which tells cron to send nothing.  A
script with no C<mailto> sends its output to the admin.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{from} = Provisioner::Utils::qualify_address( $opts{from}, $opts{domain} );

    foreach my $key (qw{root_scripts user_scripts}) {
        next unless ref $opts{$key} eq 'ARRAY';

        # A copy of each script, so that nothing here writes into the
        # configuration that the caller owns.
        my @scripts;
        foreach my $script ( @{ $opts{$key} } ) {
            if ( ref $script ne 'HASH' ) {
                push( @scripts, $script );
                next;
            }

            my $to     = $script->{mailto};
            my $mailto = !defined $to ? $opts{admin_email} : $to eq 'none' ? '' : Provisioner::Utils::qualify_address( $to, $opts{domain} );
            push( @scripts, { %$script, mailto => $mailto } );
        }
        $opts{$key} = \@scripts;
    }

    return %opts;
}

sub args {
    return (
        type       => 'object',
        properties => {

            # Not an email type: a local part is valid here, see enrich().
            from  => { type => 'string', default => 'cron', description => 'The MAILFROM of every cron file, as a local part of this domain or a whole address.' },
            files => {
                type        => 'object',
                default     => {},
                description => 'Files of the payload to install into /etc/cron.d, as the name there and the file.  Recipes that run jobs pass theirs through required_recipes.',

                # One path component each, so that no name or file leaves its
                # directory.
                propertyNames        => { pattern => '\A[A-Za-z0-9][A-Za-z0-9_.-]*\z' },
                additionalProperties => { type    => 'string', pattern => '\A[A-Za-z0-9][A-Za-z0-9_.-]*\z' },
            },
            user_scripts => {
                type  => 'array',
                items => {
                    type       => 'object',
                    required   => [qw{interval cmd}],
                    properties => {
                        interval => { type => 'string' },
                        cmd      => { type => 'string' },
                        mailto   => { type => 'string' },
                    },
                },
            },
            root_scripts => {
                type  => 'array',
                items => {
                    type       => 'object',
                    required   => [qw{interval cmd}],
                    properties => {
                        interval => { type => 'string' },
                        cmd      => { type => 'string' },
                        mailto   => { type => 'string' },
                    },
                },
            },
        },
    );
}

sub template_files {
    my ($self) = @_;

    return (
        'cron.root.tt'          => 'root.crontab',
        'cron.root.domain.tt'   => 'root.domain.crontab',
        'cron.user.tt'          => 'user.crontab',
        'cron.rkhunter.conf.tt' => 'rkhunter.conf',
    );
}

sub tests {
    return qw{cron.tt};
}

1;
