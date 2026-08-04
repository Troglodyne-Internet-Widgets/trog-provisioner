package Provisioner::Recipe::cron;

use strict;
use warnings;

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

Optionally set MAILFROM as the 'from' parameter.

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

sub validate {
    my ( $self, %vars ) = @_;

    if ( $vars{user_scripts} ) {
        die "user_scripts must be ARRAY" unless ref $vars{user_scripts} eq 'ARRAY';
        foreach my $cron ( @{ $vars{user_scripts} } ) {
            die "Each user script must be a HASH" unless ref $cron eq 'HASH';
            die "user_scripts must have an interval & cmd" unless $cron->{interval} && $cron->{cmd};
        }
    }

    if ( $vars{root_scripts} ) {
        die "root_scripts must be ARRAY" unless ref $vars{root_scripts} eq 'ARRAY';
        foreach my $cron ( @{ $vars{root_scripts} } ) {
            die "Each user script must be a HASH" unless ref $cron eq 'HASH';
            die "root_scripts must have an interval & cmd" unless $cron->{interval} && $cron->{cmd};
        }
    }

    return %vars;
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
