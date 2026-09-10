package Provisioner::Recipe::backup;

#ABSTRACT: Back up host files offsite to a backup destination.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use Provisioner::Utils;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::backup

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        backup:
            targets:
                database: "/var/lib/mysql"
                mail: "/mail"
                ...
            excludes:
                database: "foobase/ barbase/"
            key_file: "path/to/key_file_in_datadir"

=head2 DESCRIPTION

When you have files on the host which need backing up, but aren't already covered by the provisioning process itself.

Alternatively, if you want to back things up offsite inbetween provisions (almost certain you will) this makes such simple.

Pair with a VM using L<Provisioner::Recipe::backupdestination> to fully automate backups.

We backup everything described in the remote_files section of any recipe, and anything you add to 'targets' in the recipe configuration.
Ideally your recipes describe all such things sufficiently, but sometimes you have to interface with systems not provisioned by this framework.

Backups are implemented via SSH authorized key read-only restricted execution of an ephemeral & chrooted instance of rsyncd as root on port 40404.

The daemon's configuration is written to /etc/rsyncd.$DOMAIN.conf, and the forced command on the backup key names it there.
Not /root: some builds of rsync decline to read a config out of it.

What that daemon has to say goes to /var/log/rsyncd/$DOMAIN.log, rotated weekly by /etc/logrotate.d/rsyncd-backup and kept for a quarter.
Told no log file, rsyncd says it down the ssh connection instead and the machine being copied off keeps nothing: a module that fails to open, or a transfer that stops halfway, is then only visible to the destination.
Transfer logging is left off, since the destination already records what it asked for in /var/log/backups/$HOST.log; what this is for is the half of a failed backup that the destination cannot see.

TODO: Make this module consult all the other loaded recipes to know what uid/gid ought we do it as

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{targets key_file}],
        properties => {
            targets  => { type => 'object' },
            key_file => { type => 'string' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    my %default_targets;
    foreach my $module ( @{ $opts{modules} } ) {
        require "Provisioner/Recipe/$module.pm" unless Provisioner::Utils::already_required("Provisioner/Recipe/$module.pm");
        my %mtargets = "Provisioner::Recipe::$module"->remote_files( $opts{install_dir}, $opts{domain} );
        my @ts       = sort keys(%mtargets);
        foreach my $t ( 1 .. @ts ) {
            $default_targets{"$module$t"} = $ts[ $t - 1 ];
        }
    }

    my $targets = $opts{targets};
    %$targets = ( %default_targets, %$targets );

    my $kf = "$opts{data_source}/$opts{domain}/$opts{key_file}";

    $opts{pubkey} = Provisioner::Utils::ssh_pubkey_from_private($kf);
    die "Could not extract pubkey from $kf!" unless $opts{pubkey};

    return %opts;
}

sub template_files {
    return (
        "backup.rsyncd.conf.tt" => "rsyncd.conf",
        "backup.logrotate.tt"   => "backup.logrotate",
    );
}

sub tests {
    return qw{backup.tt};
}

1;
