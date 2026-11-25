package Provisioner::Recipe::cron;

#ABSTRACT: Set up the root and service user crontabs.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use List::Util();

use Provisioner::Cookbook();
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
    * rkhunter, where OSSEC does not watch the guest
    * Log watchers (OOMs, SEGVs, root access, new users, rsyslog drops,
      outgoing ufw blocks).  The watchers of OOMs, SEGVs, root access, new
      users and rsyslog drops do not run where an OSSEC manager reads the logs
      of the guest.  See L<Provisioner::Recipe::ossec/The rules that replace the log watchers>.
    * scan for writes to packaged files, with changed_packaged_files
    * dehydrated, if the domain uses the letsencrypt recipe, and something
      here writes the zone of the domain.  See
      L<Provisioner::Recipe::letsencrypt/A domain whose zone nothing here writes>.

A recipe that changes a file of a package on purpose lists it in a file of
F</etc/changed_packaged_files.d>, named for the recipe, so that the scan does
not report it.  This recipe lists the database of mirrors that rkhunter
rewrites.  L<Provisioner::Recipe::lexicon> lists the files that it patches.

=head2 Where OSSEC watches the guest

Where an OSSEC manager reads the logs of the guest, as C<ossec_watches> says,
the agent of OSSEC does the jobs of some of these.  See
L<Provisioner::Recipe::ossecagent>.  There:

=over

=item * rules on the manager replace the watchers of OOMs, SEGVs, new users and
rsyslog drops, and the agent runs root_access;

=item * rootcheck in the agent replaces rkhunter, so the guest has no rkhunter
package, configuration or job.

=back

changed_packaged_files stays.  It compares each file with the checksums of its
package, so an upgrade does not set it off.  syscheck in the agent sees every
change, an upgrade included, so most of its alerts go to the dashboard and not
to mail.  The manager mails the ones for the programs that no package owns and
for the account files, which rkhunter also watched.

The collector runs the manager and no agent, so it keeps rkhunter.  So does a
guest that ships its logs nowhere, or somewhere outside this installation.

They also run each configured C<root_scripts> entry, from a PATH that starts
with C<script_dir>.  The service user runs each C<user_scripts> entry, from a
PATH that starts with the C<bin/> directory of the service install dir.

=head1 METHODS

=head2 %opts = $recipe->enrich(%opts)

Sets what MAILFROM and each MAILTO say, and returns the options.

It also sets C<renews_certificate>, which is true where the letsencrypt recipe
set up dehydrated for the domain, and C<ossec_watches>, which is true where
L<Provisioner::Recipe::ossec/watches> is.

A local part in C<from> or C<mailto>, for example C<from: cron>, gets this
domain appended.  An address does not change, because a second domain gives
C<somebody@example.test@this.domain>.

C<mailto: none> becomes an empty MAILTO, which tells cron to send nothing.  A
script with no C<mailto> sends its output to the admin.

Returns C<%opts>, with C<from> qualified, C<renews_certificate> and
C<ossec_watches> added, and C<root_scripts> and C<user_scripts> replaced by
copies whose C<mailto> is set.

    my %opts = $recipe->enrich(
        domain       => 'test.test',
        from         => 'cron',
        admin_email  => 'admin@test.test',
        modules      => ['cron'],
        root_scripts => [ { interval => '@daily', cmd => 'true', mailto => 'none' } ],
    );

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{from} = Provisioner::Utils::qualify_address( @opts{qw(from domain)} );

    my $certified = List::Util::any { $_ eq 'letsencrypt' } @{ $opts{modules} // [] };
    $opts{renews_certificate} = ( $certified && !Provisioner::Cookbook->load('registrar')->unmanaged( $opts{domain} ) ) ? 1 : 0;
    $opts{ossec_watches}      = $self->ossec_watches( $opts{domain} );

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

=head2 $bool = $recipe->ossec_watches($domain)

True where an OSSEC manager reads the logs of C<$domain>, as
L<Provisioner::Recipe::ossec/watches> decides.  See L</Where OSSEC watches the
guest>.

=over 4

=item domain - Str - the domain of the guest

=back

Returns what L<Provisioner::Recipe::ossec/watches> returns for C<$domain>,
true or false.

    my $watched = $recipe->ossec_watches('test.test');

=cut

sub ossec_watches {
    my ( $self, $domain ) = @_;
    return Provisioner::Cookbook->load('ossec')->watches($domain);
}

# The name of a job, which names its file in cron.d.
my $JOB_NAME = qr/\A [[:alnum:]] [[:alnum:]_.-]* \z/;

=head2 %schema = $recipe->args()

The schema of the options: C<from>, a local part or an address; C<files>, an
object from the name of a job in F</etc/cron.d> to the file of the payload;
and C<user_scripts> and C<root_scripts>, lists of objects of C<interval> and
C<cmd>, which are required, and C<mailto>.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

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
                propertyNames        => { pattern => "$JOB_NAME" },
                additionalProperties => { type    => 'string', pattern => "$JOB_NAME" },
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

=head2 %files = $recipe->template_files()

The crontabs of root, of root for the domain and of the service user, the
configuration and the defaults of rkhunter, and the job that checks the
packaged files for changes, the same on every guest.

Returns a list of pairs, from each template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    my ($self) = @_;

    return (
        'cron.root.tt'                   => 'root.crontab',
        'cron.root.domain.tt'            => 'root.domain.crontab',
        'cron.user.tt'                   => 'user.crontab',
        'cron.rkhunter.conf.tt'          => 'rkhunter.conf',
        'cron.rkhunter.default.tt'       => 'rkhunter.default',
        'cron.changed_packaged_files.tt' => 'cron.changed_packaged_files',
    );
}

=head2 @tests = $recipe->tests()

Returns a list of the test templates that run on the guest: F<cron.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{cron.tt};
}

1;
