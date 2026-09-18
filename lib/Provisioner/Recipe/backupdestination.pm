package Provisioner::Recipe::backupdestination;

#ABSTRACT: Act as the offsite rsync destination for host backups.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

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

With this configuration, the guest copies the rsync module C<database> from some.domain.name into /backup/some.domain.name/$DATE/database every night.
It does the same for each target on each host.
$DATE is the date as C<date -I> prints it.

=head2 DESCRIPTION

Copies offsite the files that L<Provisioner::Recipe::backup> serves on each host.
Pair it with that recipe to automate the backups.

Each entry in C<hosts> is a host name, with an optional C<:PORT> for ssh.
The port is 22 when you do not give one.

Each entry in C<targets> is the name of an rsync module that the backup recipe serves, and the guest copies each one from every host.
The recipe also adds a target for each path in the C<remote_files> of each recipe on this guest.

C<key_file> is the path of the private key, relative to the data directory of the domain.
It is the private half of the key that the backup recipe authorizes on each host.
If the file does not exist, the recipe dies with C<key_file defined in [backupdestination] must exist in ...>.

A backup script runs every day at midnight.
It copies each target into C<base_dir>/$HOST/$DATE/$TARGET, and hard-links the files that did not change to the copy of the day before.
A retention script runs every Friday at noon and deletes each copy that is older than one month.

TODO: Make the retention period configurable.

While a backup of a host runs, the script keeps the file /root/backup_in_progress_$HOST.
A second backup of that host exits while the file exists.
Other jobs can also use it, for example to hold off a reboot until the backup ends.

The scripts log to /var/log/backups/$HOST.log, and logrotate rotates those logs weekly.

To keep the backups when the guest is rebuilt, mount a separate disk at C<base_dir> with L<Provisioner::Recipe::mounts>.

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{base_dir hosts targets key_file}],
        properties => {
            base_dir => { type => 'string' },
            hosts    => {
                type  => 'array',
                items => { type => 'string' },
            },
            targets => {
                type  => 'array',
                items => { type => 'string' },
            },
            key_file => { type => 'string' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    my $hosts = $opts{hosts};
    my %host_port_map;
    @$hosts = map {
        my $host = $_;
        my $port;
        ( $host, $port ) = split( m/:/, $host );
        $port ||= 22;
        $host_port_map{$host} = $port;
        $host
    } @$hosts;
    $opts{host_port_map} = \%host_port_map;

    my @default_targets;
    foreach my $module ( @{ $opts{modules} } ) {
        require "Provisioner/Recipe/$module.pm" unless Provisioner::Utils::already_required("Provisioner/Recipe/$module.pm");    ## no critic (Modules::RequireBarewordIncludes) -- the recipe is named by configuration
        my %mtargets = "Provisioner::Recipe::$module"->remote_files( $opts{install_dir}, $opts{domain} );
        my @ts       = sort keys(%mtargets);
        foreach my $t ( 1 .. @ts ) {
            push( @default_targets, "$module$t" );
        }
    }

    $opts{targets} = [ uniq( @default_targets, @{ $opts{targets} } ) ];

    my $kf = "$opts{data_source}/$opts{domain}/$opts{key_file}";
    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
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
