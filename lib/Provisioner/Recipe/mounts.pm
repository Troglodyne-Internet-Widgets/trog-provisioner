package Provisioner::Recipe::mounts;

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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
                  mountpoint:"/mountpoint_in_installdir"
                  device:"my_bucket_name"

=head2 DESCRIPTION

Attach a disk to the provisioned VM, or fusemount something as the application's user.

This is useful in the event you have storage hardware of varying capabilities,
or if you have a mount requiring secrets to use, such as an AWS bucket.

This recipe is quite useful in conjunction with the 'backuphost' recipe.

If you want to setup a chroot-mount in the install_dir, use setup_chroot_mount in the script_dir within your application recipe.

You'll obviously want to have your application's recipe include the relevant FUSE driver (s3fs for the example above).

TODO: make this support more than 10 fusemounts at a time (csplit issue).

In the event that a pool is specified in a disk, specify the path relative to that pool.
Otherwise, use an absolute path to the file or device.

Optionally, you can specify a partition number in a disk, we use 1 by default.

=cut

use parent qw{Provisioner::Recipe};

sub args {
    return (
        type       => 'object',
        properties => {
            disks => {
                type  => 'array',
                items => {
                    type => 'object',
                    parameters => {
                        type       => { type => 'string' },
                        options    => { type => 'string' },
                        mountpoint => { type => 'string' },
                        device     => { type => 'string' },
                    },
                 },
            },
            fuse => {
                type  => 'array',
                items => {
                    type => 'object',
                    parameters => {
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
            $disk->{pool} //= 'tf_disks';

            if (-d $disk->{device}) {
                $disk->{type} = 'virtiofs';
                $disk->{partition} = 'NONE';
                #XXX It is more important to boot than have this fail
                $disk->{options} = 'default,nofail';
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
