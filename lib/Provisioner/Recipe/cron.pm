package Provisioner::Recipe::cron;

#ABSTRACT: Set up the root and service user crontabs.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

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

If you do not want the output of a script, set its C<mailto> to C<none>.  If
you do not set C<mailto>, the output goes to the admin.

C<from> and each C<mailto> can be a local part alone or a whole address.  A
local part gets this domain appended.  An address does not change.

=head2 DESCRIPTION

Sets up the cron jobs of root, and the cron jobs of the service user.

C<from> sets MAILFROM, and defaults to C<cron>, so mail from a job comes from
C<cron@> the domain and not from the user that ran it.  Only cronie reads
MAILFROM.  The C<cron> of Debian ignores it and sends as the user, so a recipe
that writes MAILFROM into a cron file must require this recipe, which installs
cronie.

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

=head3 $address = Provisioner::Recipe::cron->mail_from($domain)

Returns the MAILFROM of C<$domain>: its C<from>, or the default of the schema,
with the domain appended to a local part.  This is the value that the crontabs
of this recipe get.  A recipe that writes a cron file of its own renders this
into it, and requires this recipe.

Reads the configuration of the domain, so it gives the same answer before and
after validation.

=cut

sub mail_from {
    my ( $class, $domain ) = @_;

    my %args = $class->args();
    my $from = Provisioner::Cookbook->domain_config($domain)->{cron}{from} // $args{properties}{from}{default};

    return Provisioner::Utils::qualify_address( $from, $domain );
}

sub args {
    return (
        type       => 'object',
        properties => {

            # Not an email type: a local part is valid here, see enrich().
            from         => { type => 'string', default => 'cron', description => 'The MAILFROM of every cron file, as a local part of this domain or a whole address.' },
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
