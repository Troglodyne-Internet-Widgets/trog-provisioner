package Provisioner::Recipe::cron;

#ABSTRACT: Set up the root and service user crontabs.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use Data::Validate::Email();

=head1 Provisioner::Recipe::cron

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        cron:
            from: foo@bar.baz
            user_scripts:
                - cmd: some_script.sh
                  interval: "5 0 0 0 0"
				  mailto: "whee@test.test"
		    root_scripts:
				...

Set mailto to 'none' if you don't care about the output of a script; say nothing
and it goes to the admin.

C<from>, and each C<mailto>, may be a bare local part or a whole address.  A
local part gets this domain appended; an address is left alone.

=head2 DESCRIPTION

Sets up some root crons, and a cron for the service user.

Optionally set MAILFROM as the 'from' parameter.  It is the local part alone --
C<cron> gives you C<cron@$domain> -- because the domain is appended for you.

Root Crons:

    * SAR gathering
    * rkhunter
    * Various log watchers (OOMs, SEGVs, root logins, new users, rsyslog drops)
    * scan for writes to packaged files
    * running dehydrated if using the letsencrypt target

Also runs all the configured root_scripts & user_scripts present in the service install dir's bin/ directory.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{rkhunter sysstat cronie debsums};
    }
    die "Unsupported packager";
}

=head3 %opts = $recipe->enrich(%opts)

Work out what MAILFROM and each MAILTO should actually say.

Both are addresses by the time cron reads them, but a bare local part is the
natural way to write one in a recipe -- C<from: cron> -- so anything that is not
already an address gets this domain appended.  Anything that is one is left
exactly as it stands, because appending to it would produce
C<somebody@example.com@this.domain>.

A script that says C<mailto: none> does not want its output, which cron spells
as an empty MAILTO.  A script that says nothing at all has not been thought
about, which is a different thing, and its output goes to the admin.  Those two
used to be the wrong way round.

=cut

sub enrich {
    my ($self, %opts) = @_;

    $opts{from} = _qualify($opts{from}, $opts{domain});

    foreach my $key (qw{root_scripts user_scripts}) {
        next unless ref $opts{$key} eq 'ARRAY';
        $opts{$key} = [map { _with_mailto($_, \%opts) } @{ $opts{$key} }];
    }

    return %opts;
}

# A local part becomes one; an address stays one.
sub _qualify {
    my ($value, $domain) = @_;

    return $value unless defined $value && length $value;
    return $value if Data::Validate::Email::is_email($value);
    return $value unless defined $domain && length $domain;
    return "$value\@$domain";
}

# Copied rather than edited in place: render_file runs once per template, and
# the recipe config it is handed belongs to the caller.
sub _with_mailto {
    my ($script, $opts) = @_;
    return $script unless ref $script eq 'HASH';

    my %out = %$script;
    my $to  = $out{mailto};

    $out{mailto} =
        !defined $to    ? $opts->{admin_email}
      : $to eq 'none'   ? ''
      :                   _qualify($to, $opts->{domain});

    return \%out;
}

sub args {
    return (
        type       => 'object',
        properties => {
            # A local part, not an address: the templates write
            # MAILFROM="[% from %]@[% domain %]" and supply the domain
            # themselves.  This was declared as an email, which asked for
            # exactly the value that would render as user@host@domain.
            from => { type => 'string' },
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
