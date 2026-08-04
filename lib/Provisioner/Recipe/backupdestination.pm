package Provisioner::Recipe::backupdestination;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

use List::Util qw{uniq};

=head1 Provisioner::Recipe::backupdestination

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        backupdestination:
            base_dir: /backup
            targets:
                - database
                - mail
                ...
            hosts:
                - "some.domain.name:2222"
                - "some.other.domain"
            key_file: "path/to/private_key_in_the_datadir"

Would result in the rsync module 'database' being backed up to /backup/some.domain.name/mysql/$DAY, and so on for each target/domain.

=head2 DESCRIPTION

When you have files on the host which need backing up, but aren't already covered by the provisioning process itself.

Pair with a VM using L<Provisioner::Recipe::backup> to fully automate backups.

Backups are implemented via SSH authorized key read-only restricted execution of rsyncd as root.

Uses a backup and retention script for the configured host(s), backing up every day at midnight and pruning to 6mos every friday noon.

TODO: make retention period configurable, etc

Touches the file '/root/backup_in_progress' while running in case you want to use that to lock behaviors such as reboots to not disrupt backups.

Logs backup output to /var/log/backups/$HOST.log, and rotates the logs.

You'll probably want to use a separate disk mounted as the base_dir via L<Provisioner::Recipe::extradisk> to persist backups between deploys.

=cut

sub deps {
    my ( $self, %opts ) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{rsync openssh-server};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    my $base_dir = $opts{base_dir};
    die "Must define base_dir in [backupdestination] section of recipes.yaml" unless $base_dir;

    my $hosts = $opts{hosts};
    die "Must define hosts in [backupdestination] section of recipes.yaml" unless $hosts;
    die "hosts in [backupdestination] must be ARRAY" unless ref $hosts eq 'ARRAY';

    my %host_port_map;
    @$hosts = map {
        my $host = $_;
        my $port;
        ($host, $port) = split(/:/, $host);
        $port ||= 22;
        $host_port_map{$host} = $port;
        $host
    } @$hosts;
    $opts{host_port_map} = \%host_port_map;

    # Gather all the remote_files
    my @default_targets;
    foreach my $module ( @{ $opts{modules} } ) {
        require "Provisioner/Recipe/$module.pm" unless Provisioner::Utils::already_required("Provisioner/Recipe/$module.pm");
        my %mtargets = "Provisioner::Recipe::$module"->remote_files( $opts{domain} );
        my @ts       = sort keys(%mtargets);
        foreach my $t ( 1 .. @ts ) {
            push( @default_targets, "$module$t" );
        }
    }

    my $targets = $opts{targets};
    die "Must define targets ns in [backupdestination] section of recipes.yaml" unless $targets;
    die "targets in [backupdestination] must be ARRAY" unless ref $targets eq 'ARRAY';

    # Merge the remote_files and specified backup stuff
    $targets = [ uniq( @default_targets, @$targets ) ];

    my $key_file = $opts{key_file};
    die "Must define key_file in [backupdestination] section of recipes.yaml" unless $key_file;
    my $kf = "$opts{data_source}/$opts{domain}/$key_file";
    die "key_file defined in [backupdestination] must exist in $kf" unless -f $kf;

    return %opts;
}

sub template_files {
    return (
        'backupdestination.cron.tt'      => 'backupdestination.cron',
        'backupdestination.logrotate.tt' => 'backupdestination.logrotate',
    );
}

sub tests {
    return qw{backupdestination.tt};
}

1;
