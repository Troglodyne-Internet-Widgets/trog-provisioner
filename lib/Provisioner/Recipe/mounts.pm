package Provisioner::Recipe::mounts;

#ABSTRACT: Attach disks and fusemounts to the provisioned VM.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 Provisioner::Recipe::mounts

=head2 SYNOPSIS

    somedomain:
        mounts:
            disks:
                - type: "reiser2"
                  options: "noatime,noexec"
                  mountpoint: "/mountpoint_on_guest"
                  device: "device_dir_or_file_on_HV"
                  partition: 2
                  pool: tf_disks
            fuse:
                - type: "s3fs"
                  options: "ro"
                  mountpoint: "/mountpoint_in_installdir"
                  device: "my_bucket_name"

=head2 DESCRIPTION

Attach a disk to the provisioned VM, or make a FUSE mount as the user of the
application.

Use it when you have storage hardware of different capabilities, or a mount that
needs secrets, such as an AWS bucket.  L<Provisioner::Recipe::backupdestination>
uses it to keep its backups on a separate disk.

For a chroot mount in the install_dir, use setup_chroot_mount in the script_dir
from the recipe of your application.

The recipe of your application must install the FUSE driver for each mount (s3fs
for the example above).

If a disk names a pool, give its device as a path relative to that pool.
Otherwise, give an absolute path to the file or device.

A disk can name a partition number.  The default is 1.

=cut

use parent qw{Provisioner::Recipe};

sub args {
    return (
        type       => 'object',
        properties => {
            disks => {
                type  => 'array',
                items => {
                    type       => 'object',
                    properties => {
                        type       => { type => 'string' },
                        options    => { type => 'string' },
                        mountpoint => { type => 'string' },
                        device     => { type => 'string' },

                        # enrich overrides pool for a device that is a directory or a
                        # block device on the hypervisor, and partition for a directory.
                        partition => { type => 'integer', minimum => 1,          default     => 1 },
                        pool      => { type => 'string',  default => 'tf_disks', description => 'The storage pool on the hypervisor that device is a volume in.' },
                    },
                },
            },
            fuse => {
                type  => 'array',
                items => {
                    type       => 'object',
                    properties => {
                        type       => { type => 'string' },
                        options    => { type => 'string' },
                        mountpoint => { type => 'string' },
                        device     => { type => 'string' },
                    },
                },
            },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    my $disks = $opts{disks};
    if ($disks) {
        foreach my $disk (@$disks) {
            $disk->{servicename} = $disk->{mountpoint};
            $disk->{servicename} =~ s|/|_|g;
            $disk->{pool} = 'raw' if -b $disk->{device};
            $disk->{pool} = 'dir' if -d $disk->{device};

            if ( -d $disk->{device} ) {
                $disk->{type}      = 'virtiofs';
                $disk->{partition} = 'NONE';

                # nofail, because a boot that succeeds matters more than this mount.
                $disk->{options} = 'defaults,nofail';
            }
        }
    }

    my $fuse = $opts{fuse};
    if ($fuse) {
        foreach my $disk (@$fuse) {
            $disk->{servicename} = $disk->{mountpoint};
            $disk->{servicename} =~ s|/|_|g;
            $disk->{pool} //= 'fuse';
        }
    }

    return %opts;
}

sub template_files {
    my ( $self, @recipes ) = @_;

    return (
        'mounts.fuse.service.tt' => 'fusemounts.txt',
        'mounts.tt'              => 'mounts.txt',
    );
}

sub tests {
    return qw{mounts.tt};
}

1;
