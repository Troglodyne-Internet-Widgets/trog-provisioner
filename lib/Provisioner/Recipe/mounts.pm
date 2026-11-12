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
                  pool: default
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
Otherwise, give an absolute path to the file or device.  The path is on the
hypervisor, and the hypervisor says whether it is a directory or a block device,
not the machine that runs F<bin/new_config>.

A disk can name a partition number.  The default is 1.

A device that is a directory on the hypervisor is shared in over virtiofs, and
F<scripts/mount_virtiofs> mounts it on the guest.  The build fails when the
share does not mount.  The mount point under the share is an empty immutable
directory, so while the share is not mounted, a write to the mount point fails
and does not go to the root disk.  The share mounts before local-fs.target on
each boot, so before the services of the guest start.

In the build, the target of this recipe runs after the global targets and
before the target of every other recipe, so that each recipe writes to what is
mounted.  C<targets_in_order> in F<bin/new_config> says why it cannot run
earlier.

The salvage before a rebuild fetches nothing from under a share or a FUSE
mount, because the files are not on the guest.  Back them up where they live.
See L<Provisioner::Recipe/remote_mountpoints>.

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
                        partition => { type => 'integer', minimum => 1,         default     => 1 },
                        pool      => { type => 'string',  default => 'default', description => 'The storage pool on the hypervisor that device is a volume in.' },
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

            # The device is on the hypervisor, so the hypervisor answers.  A
            # relative device is a volume in its pool, and needs no question.
            next unless ( $disk->{device} // q{} ) =~ m{\A/};
            my $hv = $self->hv;
            $disk->{pool} = 'raw' if $hv->is_block_device( $disk->{device} );

            if ( $hv->is_dir( $disk->{device} ) ) {
                $disk->{pool}      = 'dir';
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

# A disk in a pool or a block device is attached to the guest, and is left out.
sub remote_mountpoints {
    my ( $self, %opts ) = @_;
    my %v = $self->validated(%opts);
    return map { $_->{mountpoint} } ( grep { $_->{pool} eq 'dir' } @{ $v{disks} // [] } ), @{ $v{fuse} // [] };
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
