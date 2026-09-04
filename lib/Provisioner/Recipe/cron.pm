package Provisioner::Recipe::cron;

#ABSTRACT: Set up the root and service user crontabs.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

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

Set mailto to 'none' if you don't care about the output of a script.

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
