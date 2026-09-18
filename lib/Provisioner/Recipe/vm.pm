package Provisioner::Recipe::vm;

#ABSTRACT: The machine a guest runs on, rather than what runs on it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use File::Slurper();

=head1 NAME

Provisioner::Recipe::vm - the virtual machine itself: its size, what its disks
take, and the hypervisor XML that defines it.

=head1 SYNOPSIS

    _base:
        _global:
            memory: 8192
            cpus:   4
            size:   85899345920
            disk_cache: none
            disk_total_iops_sec: 2000

=head1 DESCRIPTION

Every other recipe describes something that runs I<on> a guest.  This one
describes the guest itself.  It sets the memory and the CPUs that the guest
gets, the size of its disk, and each setting that controls how qemu does disk
I/O.

It renders the libvirt domain XML.  A hypervisor must answer questions before
that file can be written.  So the files of this recipe are generated when
C<bin/provision> runs, not by C<bin/new_config> like the files of every other
recipe.  See L</WHEN IT IS GENERATED>.

Its settings live in the C<_global> of a domain.  C<bin/new_config> copies them
from there into F<provision.conf>, which C<bin/provision> reads.
C<bin/recipes vm> prints this schema, which describes each setting.
F<example.test/provision.conf> lists the keys and points here.

=head2 It directs the build rather than running in it

C<is_module> is false.  This recipe has no makefile fragment, because all of
its work happens before the guest exists to run a makefile.  Every distro recipe
depends on this one.  See L<Provisioner::DistroRecipe>.

=head2 Nothing is emitted blind

libvirt accepted most of these attributes before qemu implemented them.  So a
setting that this hypervisor is too old for gives one of two results.  The
domain is defined and does not start, or it starts and silently does something
else.  So C<enrich> asks L<Trog::HV/supports> about each setting.  It leaves out
each one that this machine does not take, and prints a message about it.

The throttles are the exception.  Any other setting that fails open only leaves
a guest untuned.  A throttle that is silently not applied leaves somebody who
believes in a limit that does not exist.  So an unsupported throttle is fatal.

=head2 WHEN IT IS GENERATED

The XML names a storage volume, a backing image and a seed ISO.  It names them
by paths that do not exist until something makes them.  C<create_storage> makes
them and returns what the template needs.  Then C<generate_files> renders the
XML, as it does for any other recipe.  C<Trog::HV::Libvirt::provision_guest>
calls both, because it is the code that has a hypervisor.  C<bin/provision>
calls it.

The split is deliberate.  Everything specific to libvirt is in this recipe and
its template.  So a second virtualization platform needs another recipe and
another template, not a rewrite of C<bin/provision>.

=cut

# The limits, in the order libvirt wants them.
my @IOTUNE_KEY = qw{
  total_bytes_sec read_bytes_sec write_bytes_sec
  total_iops_sec  read_iops_sec  write_iops_sec
};

=head1 METHODS

=head2 $bool = $recipe->is_module()

False.  See L</It directs the build rather than running in it>.

=cut

sub is_module { return 0 }

=head2 %args = $recipe->args()

What the machine of a guest takes.

The C<disk_*> keys deliberately declare no defaults.  C<bin/new_config> writes
each schema default into F<provision.conf>.  An absent key is how a guest says
"use what this hypervisor decides", and that is the purpose of asking the
hypervisor.  Their real defaults are in C<enrich>, where the answer depends on
what libvirt and qemu take.

=cut

sub args {
    return (
        type       => 'object',
        required   => ['image'],
        properties => {

            # What the hypervisor made or already had, which the domain XML
            # names.  The template reads them, so they are declared.  The build
            # supplies them and hv_settings skips readOnly keys.  So _global
            # cannot point a guest at a volume or a MAC that nobody created.
            #
            # These come before the iotune map, because map takes every item up
            # to the end of the enclosing list.  A property after the map
            # becomes an argument to it.
            pool_name      => { type => 'string',  readOnly => 1, description => 'Storage pool this disk was made in, as libvirt names it.' },
            disk_volume    => { type => 'string',  readOnly => 1, description => 'Volume holding the guest disk, inside pool_name.' },
            cloudinit      => { type => 'string',  readOnly => 1, description => 'The cloud-init seed ISO built for this guest, as a path on the hypervisor.' },
            bridge_device  => { type => 'string',  readOnly => 1, description => "Host bridge the guest's bridged interface is attached to." },
            nat_mac        => { type => 'string',  readOnly => 1, description => "MAC of the guest's NAT interface.  Derived from the domain name, so a rebuild keeps the lease it had." },
            bridge_mac     => { type => 'string',  readOnly => 1, description => "MAC of the guest's bridged interface, derived the same way." },
            metadata_cache => { type => 'integer', readOnly => 1, description => 'qcow2 metadata cache for this disk, in bytes.  A function of how large the image is, so the hypervisor sizes it rather than the schema defaulting it.' },
            uuid           => { type => 'string',  readOnly => 1, description => 'The uuid libvirt already gave this domain, so a rebuild that kept the disk is redefined under it.  Absent on a first build, where the template leaves the element out.' },

            image => {
                type        => 'string',
                description => 'Cloud image the guest disk is layered over, as a URL.  Supplied by the distro recipe; see Provisioner::DistroRecipe.',
            },
            memory => {
                type        => 'integer',
                default     => 8092,
                description =>
                  'Memory promised to the guest, in MB.  Counted against the hypervisor as committed rather than used, since a guest promised 8G is holding 8G whether it touches it or not.  The default is what a domain carrying the perl recipe needs: that builds perl from source and installs Perl::Critic and friends with their test suites, which in 2GB thrashes rather than fails -- a provision takes hours with nothing in any log to say why.',
            },
            cpus => {
                type        => 'integer',
                default     => 4,
                description => 'Virtual CPUs.  Overcommitted across the fleet, unlike memory; see hypervisors.conf.  Defaulted alongside memory, and for the same build.',
            },
            size => {
                type        => 'integer',
                default     => 42949672960,
                description => 'Guest disk, in bytes.  An overlay on the shared base image, so this is what it may grow to rather than what it takes now.',
            },
            cpu_mode => {
                type        => 'string',
                default     => 'host-passthrough',
                description => "libvirt <cpu mode>.  The default shows the guest the hypervisor's real CPU, including AVX and friends, which anything probing cpuid for vector extensions needs.  host-model or a named model buys migratability to a differently specced machine instead.",
            },
            disk_cache => {
                type        => 'string',
                description => "How the host caches this disk.  Defaults to none -- O_DIRECT -- so the host does not hold a second copy of every block the guest is already caching.  What that gives up is the shared base image, which writeback lets the host cache once for every guest.  A pool that will not take an O_DIRECT write is downgraded to writeback with a reason printed.",
            },
            disk_io => {
                type        => 'string',
                description => "AIO backend.  Left to qemu unless set.  io_uring is one ring shared with the kernel rather than a worker thread and a syscall per request, and needs libvirt 6.3 with qemu 5.0; native and threads are the older two.",
            },
            disk_detect_zeroes => {
                type        => 'string',
                description => "Detect all-zero writes and, with the discard path on, punch them out of the image.  Off by default: it is a check on every write for space the guest never asked to reclaim, and the guest's weekly fstrim already reclaims what it actually freed.",
            },
            disk_iothreads => {
                type        => 'integer',
                description => "Threads qemu processes this guest's disk requests on.  Defaults to 1, which is what gets submission off qemu's main loop.  0 leaves it there.  More than one is worth asking for on a guest with several busy disks; one disk's queues are only spread across several threads on libvirt 10 with qemu 9.",
            },
            disk_queues => {
                type        => 'integer',
                description => 'Virtqueues on the disk.  Defaults to the vcpu count.',
            },
            disk_logical_block_size => {
                type        => 'integer',
                description => 'Logical sector size announced to the guest.  Defaults to 512.',
            },
            disk_physical_block_size => {
                type        => 'integer',
                description => 'Physical sector size announced to the guest.  Defaults to 4096, so a guest lays its filesystem out for 4K rather than doing read-modify-write against 4K hardware for the life of the disk.  This has to be right before the guest makes its filesystem; changing it afterwards realigns nothing.',
            },
            map {
                (
                    "disk_$_" => {
                        type        => 'integer',
                        description =>
                          "libvirt iotune $_.  Unset by default: hypervisors.conf reserves memory, CPUs and disk space and reserves nothing of the I/O every guest on the machine shares a queue for, and this is the knob that answers that.  Applied per disk rather than per domain, so a guest with three disks can do three times what a number here says.  A total may not be given alongside the halves it is the total of.",
                    }
                )
            } @IOTUNE_KEY,
        },
    );
}

=head2 %files = $recipe->template_files()

The domain XML and the device map.

=cut

sub template_files {
    return (
        'vm.domain.xml.tt'  => 'domain.xml',
        'vm.devices.map.tt' => 'devices.map',
    );
}

=head2 %facts = $recipe->create_storage(%opts)

Makes what the domain XML points at, and returns the paths.  It makes four
things on the hypervisor:

=over

=item * The storage pool, if the hypervisor has none.

=item * The base image, if the hypervisor did not download it yet.

=item * The disk of this guest, as an overlay on the base image.

=item * The cloud-init seed ISO, from the three NoCloud files.

=back

None of their paths can go into the XML before they exist.  That is why this is
separate from rendering, and why C<enrich> does not do it.

Takes C<domain>, C<image>, C<size> and C<seed>.  C<seed> is a hashref of the
three NoCloud files, C<user-data>, C<meta-data> and C<network-config>.  Dies if
one is missing, because cloud-init ignores a seed without all three.  The guest
then boots without a user on it.

Returns C<pool_name>, C<disk_volume>, C<cloudinit>, C<bridge_device>,
C<nat_mac> and C<bridge_mac>.  It also returns C<metadata_cache> when the disk
is large enough to need one.

=cut

sub create_storage {
    my ( $self, %opts ) = @_;

    my $hv     = $self->hv;
    my $domain = $opts{domain};

    foreach my $file (qw{user-data meta-data network-config}) {
        die "No $file to build the cloud-init seed for $domain from\n"
          unless $opts{seed}{$file};
    }

    my $volume = "$domain-qcow2";
    $hv->pool();
    my $base = $hv->base_image( $opts{image} );
    $hv->create_disk( $volume, backing => $base, capacity => $opts{size} );

    my %qcow2 = $hv->qcow2_tuning( $opts{size} );

    return (
        pool_name     => $hv->pool_name,
        disk_volume   => $volume,
        cloudinit     => $hv->cloudinit_iso( $domain, %{ $opts{seed} } ),
        bridge_device => $hv->bridge_device,
        nat_mac       => $hv->guest_mac( $domain, 0 ),
        bridge_mac    => $hv->guest_mac( $domain, 1 ),

        # Absent, not undef, because the schema declares an integer.
        ( defined $qcow2{metadata_cache} ? ( metadata_cache => $qcow2{metadata_cache} ) : () ),
    );
}

=head2 $hv = $recipe->hv()

Returns the hypervisor that this guest is built for, as given to the
constructor.  Dies if the constructor got none.

The caller passes it in, and the recipe does not create one.  Nothing here
loads L<Trog::HV>, so loading a recipe does not load L<Sys::Virt>.

C<bin/new_config> gives one to every builder it makes.
C<Trog::HV::Libvirt::provision_guest> gives itself to the recipe it builds.
There is no default, because a hypervisor chosen here is a second answer to a
question that placement already settled.

=cut

sub hv {
    my ($self) = @_;

    return $self->{hv} // die ref($self) . " was built without a hypervisor: whoever builds it has to hand one over\n";
}

=head2 %opts = $recipe->enrich(%opts)

Works out what this hypervisor accepts, and from that, what each disk of the
guest looks like.

Takes the options of the recipe.  Returns them with C<tuning>, C<tpm>,
C<partition>, C<nat_slot>, C<bridge_slot>, C<disks>, C<filesystems> and
C<devices_map> added.  Dies if it gets a throttle that the hypervisor does not
support, or a total throttle together with one of its halves.  Also dies if
F<mounts.txt> asks for more devices than C<vdb> to C<vdz>.

Each value it adds is a decision, not a string: which cache mode, how many
iothreads, which disk gets which of the iothreads, and what F<mounts.txt> asks
for.  The template writes the XML.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my $hv        = $self->hv;
    my $iothreads = $self->_iothreads( \%opts );

    my %tuning = (
        cache            => $self->_cache( \%opts ),
        io               => $self->_io( \%opts ),
        discard          => $hv->supports('discard') ? 1 : 0,
        detect_zeroes    => $self->_detect_zeroes( \%opts ),
        discard_no_unref => $hv->supports('discard_no_unref') ? 1 : 0,
        iothreads        => $iothreads,
        mapping          => ( $iothreads > 1 && $hv->supports('iothread_mapping') ) ? 1 : 0,
        queues           => $self->_queues( \%opts ),
        blockio          => $self->_blockio( \%opts ),
        iotune           => $self->_iotune( \%opts ),

        # create_storage asks the hypervisor for this, because the size of the
        # image decides it.
        metadata_cache => $opts{metadata_cache},
    );

    $opts{tuning} = \%tuning;
    $opts{tpm}    = $self->_tpm;

    # The cgroup partition for every guest on this hypervisor.  libvirt uses
    # /machine when none is named, so unset means the same thing.  An operator
    # names one to put every guest built here into one systemd slice to cap.
    $opts{partition} = $hv->partition;

    # The PCI slots of the two interfaces, as libvirt writes them.  The
    # hypervisor decides, because the interface names on the guest come from
    # these.  See Trog::HV::nic_names.
    ( $opts{nat_slot}, $opts{bridge_slot} ) = map { sprintf '0x%02x', $_ } $hv->nic_slots;

    my ( $disks, $filesystems, $devices ) = $self->_devices( \%opts, \%tuning );
    $opts{disks}       = $disks;
    $opts{filesystems} = $filesystems;
    $opts{devices_map} = $devices;

    return %opts;
}

=head1 INTERNALS

Private to this module.  They are documented here for the next person to edit
them.

=head2 $bool = $recipe->_tpm()

Returns 1 if the hypervisor has a hardware TPM, and the guest then gets an
emulated one.  Otherwise prints a message and returns 0.

C<swtpm> keeps the TPM state of a guest in a file on the hypervisor, next to the
disk image of the guest.  A key sealed to that TPM is sealed to that file, so
whoever takes the disk also takes the TPM.  That has value when hardware
protects the disk of the hypervisor.  When it does not, it is worse than
nothing, because software on the guest uses the TPM and trusts it.

=cut

sub _tpm {
    my ($self) = @_;
    return 1 if $self->hv->has_tpm;

    print "No hardware TPM on the hypervisor, so this guest gets none either\n";
    return 0;
}

=head2 $value = _asked(\%opts, $key)

Returns the value of C<$key>, or undef if that value is false.  An absent key,
a key with nothing after the C<=>, and C<0> are all false.  L<Config::Simple>
tells the first two apart, and nothing here needs to.

=cut

sub _asked {
    my ( $opts, $key ) = @_;
    return undef unless length $opts->{$key};    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- "0" is an answer: disk_iothreads=0 turns iothreads off
    return $opts->{$key};
}

=head2 $mode = $recipe->_cache(\%opts)

Returns the cache mode for the disks.  That is C<disk_cache> if it is set, else
C<none> if the storage pool takes an O_DIRECT write.  Otherwise it prints a
message and returns C<writeback>.

The description of C<disk_cache> in the schema gives the trade between the two.
One more cost of the host page cache is that L<Trog::Hypervisors> does not count
that memory when it decides what else fits.

No version check can decide this setting.  A pool that does not take O_DIRECT
makes qemu fail to open the disk, so the domain is defined but does not start.
So the question goes to the filesystem.  See
L<Trog::HV::Libvirt/pool_takes_direct_io> for why file system names do not
answer it.

=cut

sub _cache {
    my ( $self, $opts ) = @_;
    my $hv = $self->hv;

    my $asked = _asked( $opts, 'disk_cache' );
    return $asked if $asked;
    return 'none' if $hv->pool_takes_direct_io;

    print "The storage pool, on " . $hv->pool_fstype . ", would not take an O_DIRECT write, so this\n" . "guest gets cache='writeback' rather than a domain that defines and then won't start.\n" . $self->_direct_io_advice . "Set disk_cache in provision.conf to say otherwise.\n";
    return 'writeback';
}

=head2 $text = $recipe->_direct_io_advice()

Returns advice for the operator when the pool is on ZFS, and an empty string
otherwise.

On ZFS, O_DIRECT fails for one of two causes.  The release has no Direct I/O,
or a pool or a dataset is configured not to use it.  An operator can fix
either, but only when the message says which one it is.

=cut

sub _direct_io_advice {
    my ($self) = @_;
    my $hv = $self->hv;
    return '' unless $hv->pool_fstype eq 'zfs';

    my $version = $hv->zfs_version;
    return "The pool is on ZFS and the hypervisor would not say which version; ask it with\n" . "`cat /sys/module/zfs/version`.\n"
      unless defined $version;

    return "OpenZFS is $version here and Direct I/O arrived in 2.3, so this wants an upgrade.\n"
      if _zfs_predates_direct_io($version);

    return "OpenZFS $version has Direct I/O, so it is the pool or the dataset refusing it:\n" . "`zpool get all` for the feature flags, `zfs get direct` for the property.\n";
}

=head2 $bool = _zfs_predates_direct_io($version)

Returns 1 if OpenZFS C<$version> is older than 2.3, which added Direct I/O.
Returns 0 for a later version, or for one it cannot parse.  It compares numbers,
because a string comparison puts 2.10 before 2.3.

=cut

sub _zfs_predates_direct_io {
    my ($version) = @_;
    my ( $major, $minor ) = $version =~ m/^(\d+)[.](\d+)/ or return 0;
    return ( ( $major * 1_000 ) + $minor ) < 2_003 ? 1 : 0;
}

=head2 $backend = $recipe->_io(\%opts)

Returns the AIO backend that C<disk_io> names, or undef to leave the choice to
qemu.  For C<io_uring> on a hypervisor that does not support it, prints a
message and returns undef.  It never sets a backend that nobody asked for.

=cut

sub _io {
    my ( $self, $opts ) = @_;
    my $hv = $self->hv;

    my $asked = _asked( $opts, 'disk_io' ) or return undef;
    return $asked unless $asked eq 'io_uring';
    return 'io_uring' if $hv->supports('io_uring');

    print "disk_io=io_uring needs libvirt 6.3 and qemu 5.0; " . $hv->describe . " has older,\n" . "so the disk is left on qemu's own choice of AIO backend.\n";
    return undef;
}

=head2 $mode = $recipe->_detect_zeroes(\%opts)

Returns C<disk_detect_zeroes> if it is set and the hypervisor supports it.
Otherwise returns undef, and prints a message if it was set.

It is off by default, unlike the discard path.  With C<detect_zeroes='unmap'>,
qemu inspects every write for zeros, to reclaim space that the guest did not
free.  The weekly C<fstrim> on the guest goes through C<discard='unmap'> and
reclaims what the guest freed, at no cost for each write.  So it has value only
on a guest that writes zeros in bulk.

=cut

sub _detect_zeroes {
    my ( $self, $opts ) = @_;
    my $hv = $self->hv;

    my $asked = _asked( $opts, 'disk_detect_zeroes' ) or return undef;
    return $asked if $hv->supports('detect_zeroes');

    print "disk_detect_zeroes needs libvirt 2.0; " . $hv->describe . " has older, so it is left off.\n";
    return undef;
}

=head2 $count = $recipe->_iothreads(\%opts)

Returns the number of iothreads, from C<disk_iothreads> or 1 by default.
Returns 0 if that number is negative.  Also returns 0, with a message, if the
hypervisor does not support iothreads.

Without iothreads, virtio-blk submission runs on the main loop of qemu, in
series with all other work on that loop.  More than one has value only on a
guest with several busy disks, or on a hypervisor that can spread the queues
of one disk across them.  See C<_disk>.

=cut

sub _iothreads {
    my ( $self, $opts ) = @_;
    my $hv = $self->hv;

    my $asked = _asked( $opts, 'disk_iothreads' ) // 1;
    return 0      if $asked <= 0;
    return $asked if $hv->supports('iothread');

    print "disk_iothreads needs libvirt 1.2.8 and qemu 2.1; " . $hv->describe . " has older,\n" . "so this guest's disks stay on qemu's main loop.\n";
    return 0;
}

=head2 $count = $recipe->_queues(\%opts)

Returns the number of virtqueues on each disk, from C<disk_queues> or the vcpu
count by default.  Returns undef if that number is not positive, or if the
hypervisor does not support the attribute.

Recent qemu already gives virtio-blk one virtqueue for each vcpu.  So on most of
the fleet, this only states what qemu does anyway.  The XML must state it, so
that the queues can go across iothreads.

=cut

sub _queues {
    my ( $self, $opts ) = @_;
    return undef unless $self->hv->supports('queues');

    my $asked = _asked( $opts, 'disk_queues' ) // $opts->{cpus};
    return $asked > 0 ? $asked : undef;
}

=head2 \%sizes = $recipe->_blockio(\%opts)

Returns the C<logical> and C<physical> sector sizes to announce to the guest,
512 and 4096 by default.  Returns undef if the hypervisor does not support the
element.

virtio-blk announces 512/512 by default.  The guest then lays out its
filesystem for 512 byte sectors, and does read-modify-write against 4K hardware
for the life of the disk.  4096 is safe to announce on a 512n device too.  The
guest only aligns to a boundary that the device ignores.  That is why 4096 is a
default and not a probe.

=cut

sub _blockio {
    my ( $self, $opts ) = @_;
    return undef unless $self->hv->supports('blockio');

    return {
        logical  => _asked( $opts, 'disk_logical_block_size' )  // 512,
        physical => _asked( $opts, 'disk_physical_block_size' ) // 4096,
    };
}

=head2 \@limits = $recipe->_iotune(\%opts)

Returns the throttles set in C<disk_*_bytes_sec> and C<disk_*_iops_sec>, or
undef if none is set.  Each is a hashref of C<name> and C<value>.  The list is
in the order that libvirt wants, so the template does not need to know it.

Dies if the hypervisor does not support C<iotune>.  See
L</Nothing is emitted blind>.  Also dies if a total is set together with one of
its halves, because libvirt takes a total or the two halves, never both.

F<hypervisors.conf> reserves memory, CPUs and disk space.  It reserves nothing
of the disk I/O queue that all guests on a machine share.  So one guest that
runs a backup can slow every other guest, and no capacity check predicts it.
These limits are the answer.  They are off unless a guest sets them, because a
throttle has a cost.  Only the owner of the workload knows the correct value.

=cut

sub _iotune {
    my ( $self, $opts ) = @_;
    my $hv = $self->hv;

    my %limit = map { $_ => _asked( $opts, "disk_$_" ) } @IOTUNE_KEY;
    delete @limit{ grep { !defined $limit{$_} } keys %limit };
    return undef unless %limit;

    die "disk_*_bytes_sec/disk_*_iops_sec need libvirt 0.9.8, and " . $hv->describe . " is older.\n" . "Remove them from provision.conf, or build this guest somewhere that can honor them.\n"
      unless $hv->supports('iotune');

    foreach my $unit (qw{bytes_sec iops_sec}) {
        next unless $limit{"total_$unit"};
        die "disk_total_$unit cannot be set alongside disk_read_$unit or disk_write_$unit:\n" . "libvirt takes a total or the two halves, never both.\n"
          if $limit{"read_$unit"} || $limit{"write_$unit"};
    }

    return [ map { { name => $_, value => $limit{$_} } } grep { defined $limit{$_} } @IOTUNE_KEY ];
}

=head2 (\@disks, \@filesystems, $map) = $recipe->_devices(\%opts, \%tuning)

Returns every device of the domain.  C<\@disks> starts with the disk of the
guest, then the disks that F<mounts.txt> asks for.  C<\@filesystems> holds the
C<virtiofs> shares.  C<$map> is the text that the guest gets, so it can find
them.  Dies if F<mounts.txt> asks for more devices than C<vdb> to C<vdz>.

Each line of F<mounts.txt> is C<pool=name>.  A C<raw> pool is a block device on
the host.  C<dir> is a directory shared in through C<virtiofs>, and C<file> is
an image file.  Any other pool is the name of another libvirt pool.  A C<fuse>
line is skipped, because the guest mounts those itself.

Each line of C<$map> is C<name=vdX> for a directory, or C<name=/dev/vdX> for a
disk.

=cut

sub _devices {
    my ( $self, $opts, $tuning ) = @_;

    my @disks = ( $self->_disk( $tuning, format => 'qcow2', dev => 'vda', boot => 1, index => 0, primary => 1 ) );
    my ( @filesystems, $map );
    $map = '';

    my $spec_file = "$self->{output_dir}/mounts.txt";
    ## no critic (ValuesAndExpressions::ProhibitFiletest_r)
    if ( -r $spec_file ) {
        my @devnames = ( 'vdb' .. 'vdz' );
        my $order    = 2;
        my $index    = 0;

        foreach my $diskspec ( grep { $_ } split( m/\n/, File::Slurper::read_text($spec_file) ) ) {
            my ( $pool, $disk ) = split( m/=/, $diskspec );
            next if $pool eq 'fuse';

            $order++;
            my $dev = shift @devnames or die "Ran out of vdnames!\n";

            $map .= $pool eq 'dir' ? "$disk=$dev\n" : "$disk=/dev/$dev\n";

            if ( $pool eq 'dir' ) {
                push( @filesystems, { source => $disk, target => $dev } );
                next;
            }

            $index++;

            if ( $pool eq 'raw' ) {
                push( @disks, $self->_disk( $tuning, format => 'raw', dev => $dev, boot => $order, index => $index, type => 'block', source => $disk ) );
                next;
            }

            # A file or a volume in another pool.  Both resolve to a path, and
            # libvirt wants the path.
            my $path = $pool eq 'file' ? $disk : ( $self->hv->volume_path( $disk, $pool ) // $disk );
            push( @disks, $self->_disk( $tuning, format => 'qcow2', dev => $dev, boot => $order, index => $index, type => 'file', source => $path ) );
        }
    }

    return ( \@disks, \@filesystems, $map );
}

=head2 \%disk = $recipe->_disk(\%tuning, %disk)

Returns one disk, with every attribute decided, for the template to write.
C<%disk> holds C<format>, C<dev>, C<boot> and C<index>.  An extra disk also
has C<type> and C<source>, and the disk of the guest has C<primary>.  C<type>
defaults to C<volume>.

=cut

sub _disk {
    my ( $self, $tuning, %disk ) = @_;

    $disk{type} //= 'volume';

    # Only for qcow2, because a raw block device has no cluster to keep the
    # reference to.  On qcow2, a discard from the guest punches a hole in the
    # host filesystem and keeps the cluster in the image.  So the space comes
    # back, and the qcow2 does not fragment when it rewrites what it freed.
    $disk{discard_no_unref} = ( $tuning->{discard_no_unref} && $disk{format} eq 'qcow2' ) ? 1 : 0;

    # iothread and iothreads are mutually exclusive, and only the disk that the
    # mapping is for gets it.  Every other disk gets one iothread from the pool,
    # round robin, so several disks spread out.  With the default pool of one,
    # they share it and are still off the main loop.
    my $mapped = $disk{primary} && $tuning->{mapping};
    $disk{iothread} = ( $disk{index} % $tuning->{iothreads} ) + 1
      if $tuning->{iothreads} && !$mapped;

    # No queue children, on purpose.  Given the iothreads and the queue count,
    # libvirt and qemu distribute the virtqueues themselves.  A mapping written
    # here gives the same result, with more ways to get it wrong.
    $disk{iothread_ids} = $mapped ? [ 1 .. $tuning->{iothreads} ] : [];

    # The size of the image decides the metadata cache, and only the size of
    # the primary disk is known.
    $disk{metadata_cache} = $tuning->{metadata_cache} if $disk{primary};

    return \%disk;
}

1;
