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

If you do not want the output of a script, set its C<mailto> to C<none>.  If
you do not set C<mailto>, the output goes to the admin.

C<from> and each C<mailto> can be a local part alone or a whole address.  A
local part gets this domain appended.  An address does not change.

=head2 DESCRIPTION

Sets up the cron jobs of root, and the cron jobs of the service user.

C<from> sets MAILFROM.  If you do not set it, no cron file sets MAILFROM.

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
        $opts{$key} = [ map { _with_mailto( $_, \%opts ) } @{ $opts{$key} } ];
    }

    return %opts;
}

# Return a copy, because render_file calls enrich once per template and the
# caller owns the recipe configuration.
sub _with_mailto {
    my ( $script, $opts ) = @_;
    return $script unless ref $script eq 'HASH';

    my %out = %$script;
    my $to  = $out{mailto};

    $out{mailto} =
        !defined $to  ? $opts->{admin_email}
      : $to eq 'none' ? ''
      :                 Provisioner::Utils::qualify_address( $to, $opts->{domain} );

    return \%out;
}

sub args {
    return (
        type       => 'object',
        properties => {

            # Not an email type: a local part is valid here, see enrich().
            from         => { type => 'string' },
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
