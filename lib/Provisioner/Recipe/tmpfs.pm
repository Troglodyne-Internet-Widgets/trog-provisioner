package Provisioner::Recipe::tmpfs;

#ABSTRACT: Put /tmp on a tmpfs, at a size you choose.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::tmpfs

=head2 SYNOPSIS

    somedomain:
        tmpfs:

    # Or with a size of your own:
    somedomain:
        tmpfs:
            size: 2G

=head2 DESCRIPTION

Installs a C<tmp.mount> unit, so C</tmp> is a tmpfs and not a directory on the
root filesystem.

Debian and Ubuntu put their unit in F</usr/share/systemd/> and not in
F</usr/lib/systemd/system/>. That is how they ship it turned off, because
systemd cannot enable a unit that it cannot see. So this recipe writes its own
unit to F</etc/systemd/system/tmp.mount>. That is also what makes the size
configurable. You cannot put a drop-in for a unit that does not exist.

=head3 It mounts during the build

The recipe enables the unit and starts it, in its own makefile target. A unit
that is enabled but not started does not stay that way. C<tmp.mount> is
C<WantedBy=local-fs.target>. The next C<systemctl restart> of a service with
default dependencies pulls that target in again, and that mounts it.

So the recipe mounts it at a known time. Every recipe after it sees the same
C</tmp>, and a mount that fails also fails the build.

The build payload is in F</var/tmp> (see F<templates/ubuntu/files/ubuntu.setup.sh.tt>),
so the mount does not hide it. The mount hides only what cloud-init and apt
left in C</tmp>. That is why systemd says B<Directory /tmp to mount over is not
empty, mounting anyway>.

Those files stay on the root filesystem under the mount, and nothing can reach
them. On the test guest they were about 76K of sockets and private directories
for systemd services. Every later boot mounts the tmpfs before anything writes
to C</tmp>, so they do not grow. The recipe does not delete them.

=head3 deps

None. C<tmp.mount> comes from systemd, and tmpfs comes from the kernel.

=head3 args

=over 4

=item size

The largest size that the tmpfs can grow to, in the syntax that C<mount> takes
for tmpfs. That is a percentage of RAM (C<50%>), a size with a suffix (C<2G>,
C<512M>), or a number of bytes. The default is C<50%>, the same as the
C<tmp.mount> that systemd ships.

It is a limit, not a reservation. A tmpfs uses only the memory for what is
written to it. So a large number does not take memory from the guest at boot.
It lets a process that fills C</tmp> use that much memory.

A percentage goes into the unit file doubled, as C<50%%>. systemd expands
specifiers in C<Options=>, and a single C<%> there starts one.

=back

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            size => {

                # Checked here because a bad size otherwise fails the mount at
                # boot, and /tmp stays on the disk with nobody told.
                type    => 'string',
                pattern => '^[1-9][0-9]*(?:%|[kKmMgG])?$',
                default => '50%',
            },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Options= takes a literal % as %%.  See size in the POD.
    ( $opts{unit_size} = $opts{size} ) =~ s/%/%%/;

    return %opts;
}

sub template_files {
    return (
        'tmpfs.mount.tt' => 'tmp.mount',
    );
}

sub tests {
    return qw{tmpfs.tt};
}

1;
