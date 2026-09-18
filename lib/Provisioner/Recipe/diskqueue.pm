package Provisioner::Recipe::diskqueue;

#ABSTRACT: Tell the guest's block layer it is talking to a hypervisor rather than a disk.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::diskqueue

=head2 SYNOPSIS

    somedomain:
        diskqueue:

    # Or for a guest that reads big files start to finish:
    somedomain:
        diskqueue:
            read_ahead_kb: 512

=head2 DESCRIPTION

Writes a udev rule that sets the I/O scheduler and the readahead window on the
virtio disks of the guest.  The recipe applies the rule to the disks that are
already attached, and reads back the values that the kernel actually took.

=head3 Why a guest must not schedule at all

The guest has a queue and the hypervisor has a queue, and only the hypervisor
can see the device.  The block addresses of a virtual disk have no relation to
the physical device.  So when the guest reorders, merges or delays a request,
it does work that the host then does again, correctly.  The host knows where
the platters or the flash actually are.  The work on the guest only adds
latency.

C<none> is the scheduler that does none of that work.  It submits requests in
order, and the layer that can see the hardware sorts them.

A guest can already be on C<none> or not.  The answer depends on the far side
of the same disk, so this recipe is coupled to it.

Ubuntu chooses no scheduler for a virtio disk.  No udev rule sets it.  The only
rule on the guest that mentions the setting is C<64-btrfs-zoned.rules>, for
host-managed zoned devices, and a virtio-blk is not one.  So the kernel makes
the choice, from the number of hardware queues.  One queue gets
C<mq-deadline>, and more than one gets no scheduler, which is C<none>.

The number of hardware queues is the C<queues> attribute on the disk of the
domain.  These results come from a guest, with the rule of this recipe removed
and nothing else changed:

=over 4

=item one virtqueue

C<[mq-deadline]>, with C<rotational=1>.  This is an elevator that seeks on a
disk that does not exist.

=item four virtqueues

C<[none]>.

=back

So when the domain asks for one virtqueue per vcpu, most guests are already off
C<mq-deadline> before this recipe runs.  A guest set back to
C<disk_queues: 1> goes back to an elevator without a warning.  So does a guest
on a libvirt older than 3.9, which does not have the attribute.

So on a guest with a current domain, the scheduler line pins a value that is
already there.  The pin makes the answer independent of a number that is set on
the other side of the disk.  It also reports when the kernel disagrees.  The
readahead setting is the part that changes something by itself.

=head3 Readahead, and why the default here changes nothing

C<read_ahead_kb> defaults to 128, which is also the default of the kernel.  So
by default this recipe writes the value that the disk already has, on purpose.
Of the settings here, only readahead cannot follow from the topology.  It is a
guess about the workload, and a wrong guess in either direction costs
something:

=over 4

=item * If it is too small, a guest that streams a large file makes four times
the round trips that it needs.

=item * If it is too large, a guest that does small random reads loads pages
that it never uses, and evicts pages that it uses.

=back

So the default states the answer of the kernel explicitly, and a guest that
knows better changes one line.  512 is a reasonable number for sequential
work, for example a media server, a backup target, or a database that scans
tables.

=head3 Applied now, not just at the next boot

A udev rule fires on C<add> and C<change> events.  The disks of the guest were
added long before this file existed.  So the recipe reloads the rules and
triggers a change event across the block subsystem.  That makes the setting
true on the running guest, not only after the next boot.

=head3 deps

None.  udev is part of systemd, and the queue attributes belong to the kernel.

=head3 args

=over 4

=item scheduler

The I/O scheduler to pin.  Defaults to C<none>, which a guest wants unless it
has a specific reason.  A stock Ubuntu kernel also has C<mq-deadline>, C<bfq>
and C<kyber>.  C<bfq> is the useful one for a guest where interactive work must
survive next to bulk I/O.

=item read_ahead_kb

The readahead window, in KiB.  Defaults to 128, the default of the kernel.

=item devices

The disks that the rule applies to, as udev C<KERNEL> globs.  Defaults to
C<vd*>, which is every virtio-blk disk, and so every disk that L<Trog::HV> gives
a guest.

=back

=head2 SEE ALSO

The other half of this is on the hypervisor.  L<Provisioner::Recipe::vm> sets
the cache mode, the discard path, the iothreads and the virtqueues on the far
side of the same disk.  Its C<disk_*> options change them.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            scheduler => {
                type    => 'string',
                enum    => [qw{none mq-deadline bfq kyber}],
                default => 'none',
            },

            # A ceiling, not a target.  The kernel clamps readahead to what the
            # device and the memory pressure allow.  It accepts a number in the
            # gigabytes, but never reaches it.
            read_ahead_kb => {
                type    => 'integer',
                minimum => 0,
                maximum => 1_048_576,
                default => 128,
            },
            devices => {
                type    => 'array',
                items   => { type => 'string' },
                default => ['vd*'],
            },
        },
    );
}

sub template_files {
    return (
        'diskqueue.rules.tt' => 'diskqueue.rules',
    );
}

sub tests {
    return qw{diskqueue.tt};
}

1;
