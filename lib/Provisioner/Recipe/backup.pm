package Provisioner::Recipe::backup;

use strict;
use warnings;

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

TODO: Make this module consult all the other loaded recipes to know what uid/gid ought we do it as

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

    # Gather all the remote_files
    my %default_targets;
    foreach my $module ( @{ $opts{modules} } ) {
        require "Provisioner/Recipe/$module.pm" unless Provisioner::Utils::already_required("Provisioner/Recipe/$module.pm");
        my %mtargets = "Provisioner::Recipe::$module"->remote_files( $opts{domain} );
        my @ts       = sort keys(%mtargets);
        foreach my $t ( 1 .. @ts ) {
            $default_targets{"$module$t"} = $ts[ $t - 1 ];
        }
    }

    my $targets = $opts{targets};
    die "Must define targets ns in [backup] section of recipes.yaml" unless $targets;
    die "targets in [backup] must be HASH" unless ref $targets eq 'HASH';

    # Merge the remote_files and specified backup stuff
    %$targets = ( %default_targets, %$targets );

    my $key_file = $opts{key_file};
    die "Must define key_file in [backupdestination] section of recipes.yaml" unless $key_file;
    my $kf = "$opts{data_source}/$opts{domain}/$key_file";
    die "key_file defined in [backupdestination] must exist in $kf" unless -f $kf;

    # Extract the pubkey so we don't have to schlep the pkey over to the host
    # XXX support non rsa keys ig?
    $opts{pubkey} = `ssh-keygen -yf "$kf"`;
    chomp $opts{pubkey};
    die "Could not extract pubkey!" unless $opts{pubkey};

    return %opts;
}

sub template_files {
    return (
        "backup.rsyncd.conf.tt" => "rsyncd.conf",
    );
}

1;
