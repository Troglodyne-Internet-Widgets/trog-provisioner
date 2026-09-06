package Provisioner::Recipe::diskqueue;

#ABSTRACT: Tell the guest's block layer it is talking to a hypervisor rather than a disk.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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

Writes a udev rule setting the I/O scheduler and the readahead window on the
guest's virtio disks, applies it to the disks already attached, and reads back
what the kernel actually took.

=head3 Why a guest should not be scheduling at all

There is a queue on the guest and a queue on the hypervisor, and only one of
them can see the device. Anything the guest reorders, merges or delays is work
done against a virtual disk whose block addresses have no relationship to
anything physical -- and then done again, properly, by the host, which knows
where the platters or the flash actually are. The guest's version of it is pure
latency.

C<none> is the scheduler that does none of that: submit in order and let the
layer that can see the hardware sort it out.

Whether a guest was already doing that has no fixed answer, and the reason is
worth knowing because it couples this recipe to the far side of the same disk.

Ubuntu chooses no scheduler for a virtio disk. There is no udev rule for it --
the only rule on the guest that mentions the setting is C<64-btrfs-zoned.rules>,
for host-managed zoned devices, which a virtio-blk is not. So the choice is the
kernel's own, and the kernel makes it from the number of hardware queues: one
gets C<mq-deadline>, more than one gets nothing, which is C<none>.

The number of hardware queues is the C<queues> attribute on the domain's disk.
Measured on a guest, with this recipe's rule taken away and nothing else
changed:

=over 4

=item one virtqueue

C<[mq-deadline]>, with C<rotational=1> -- an elevator seeking a disk that is not
there.

=item four virtqueues

C<[none]>.

=back

Which means C<mongle_disk_tuning> asking for one virtqueue per vcpu already
moves most guests off C<mq-deadline> before this recipe is anywhere near them --
and that a guest set back to C<disk_queues: 1>, or built on a libvirt too old
for the attribute at all (before 3.9), quietly goes back to an elevator. Every
guest here was on one, until the domain started asking for more.

So the scheduler line is a pin rather than the thing doing the moving, on a
guest whose domain is current. It is still worth pinning: it makes the answer
independent of a number set on the other side of the disk, and it says so when
the kernel disagrees. The readahead below is the half that changes something on
its own.

=head3 Readahead, and why the default here changes nothing

C<read_ahead_kb> defaults to 128, which is also the kernel's default: this
recipe writes the value it already had. That is deliberate. Readahead is the one
setting on this list that cannot be reasoned out from the topology -- it is a
guess about the workload, and a wrong guess in either direction costs something.
Too little and a guest streaming a large file makes four times the round trips
it needed. Too much and a guest doing small random reads pulls in pages it will
never look at, evicting ones it would have.

So the default states the kernel's own answer explicitly, and the guest that
knows better changes one line. 512 is a reasonable number for anything
sequential -- a media server, a backup target, a database doing table scans.

=head3 Applied now, not just at the next boot

A udev rule fires on C<add> and C<change>, and the guest's disks were added long
before this file existed. So the recipe reloads the rules and triggers a change
event across the block subsystem, which is what makes the setting true on the
running guest as well as on the next one.

=head3 deps

None. udev is systemd's and the queue attributes are the kernel's.

=head3 args

=over 4

=item scheduler

What to pin the I/O scheduler to. Defaults to C<none>, which is what a guest
wants unless it has a specific reason. C<mq-deadline>, C<bfq> and C<kyber> are
the others a stock Ubuntu kernel has -- C<bfq> being the one worth knowing
about, for a guest where interactive work has to survive alongside something
doing bulk I/O.

=item read_ahead_kb

The readahead window, in KiB. Defaults to 128, the kernel's own default.

=item devices

Which disks it applies to, as udev C<KERNEL> globs. Defaults to C<vd*>, which is
every virtio-blk disk and therefore every disk L<Trog::HV> gives a guest.

=back

=head2 SEE ALSO

The other half of this lives on the hypervisor: C<mongle_disk_tuning> in
F<bin/provision> is what decides the cache mode, the discard path, iothreads and
virtqueues on the far side of the same disk.

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

            # A ceiling rather than a target: the kernel clamps readahead to
            # what the device and the memory pressure allow, and a number in the
            # gigabytes is not refused, merely never reached.
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
