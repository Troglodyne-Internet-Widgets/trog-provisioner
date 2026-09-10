#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-vm.t - the domain XML, and what of it this hypervisor will take

=head1 DESCRIPTION

Every disk attribute here is gated on a version, because the fleet is not all
one version.  These build the same guest against an old hypervisor and a new one
and assert on the difference, which is the only part worth testing: whether the
XML is any faster is not a thing a unit test can know.

This lived in F<t/provision.t> while the XML was built by a family of subs in
F<bin/provision> concatenating strings.  It is a recipe now, so the test is a
recipe's.

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use Test::MockModule qw{strict};
use Config::Simple();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Trog::HV();
use Provisioner::Cookbook();

# What bin/provision does with the recipe, in one call: make the storage the XML
# is going to name, then generate the files.  Reads back what was written rather
# than what was returned, because the file is what libvirt is handed.
sub domain_xml {
    my ( $config, $seed ) = @_;

    my $hv       = Trog::HV->new();
    my $domain   = $config->param('domain');
    my $dir      = $hv->domain_dir . "/$domain";
    my %settings = %{ $config->param( -block => 'default' ) };

    my $vm = Provisioner::Cookbook->load('vm')->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        hv            => $hv,
    );

    my %storage = $vm->create_storage( %settings, domain => $domain, seed => $seed );
    $vm->generate_files( $dir, %settings, %storage, domain => $domain );

    return File::Slurper::read_text("$dir/domain.xml");
}

sub _conf {
    my (%params) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/provision.conf", join( '', map { "$_=$params{$_}\n" } sort keys %params ) );
    return "$dir/provision.conf";
}

sub quietly {
    my ($code) = @_;
    open( my $capture, '>', \my $out ) or die $!;
    my @result = do { local *STDOUT = $capture; $code->() };
    close $capture;
    return wantarray ? @result : $result[0];
}

# --- The cloud-init seed --------------------------------------------------
#
# These three go to Trog::HV::cloudinit_iso as a hash.  Passing it anything
# else -- a single string, say -- is an odd number of elements in a hash
# assignment, which is a warning and then a seed with no files in it.
subtest 'the seed is built from all three NoCloud files' => sub {
    my $config = Config::Simple->new(
        _conf(
            domain => 'vm.example.com', memory => 2048,
            cpus   => 2, size => 42949672960, image => 'https://example.test/img'
        )
    );

    my %got;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine( bridge_device => sub { 'br0' } );
    $hv_mock->redefine( has_tpm       => sub { 0 } );
    $hv_mock->redefine( pool          => sub { 1 } );
    $hv_mock->redefine( base_image    => sub { '/pool/baseimage-qcow2' } );
    $hv_mock->redefine( create_disk   => sub { '/pool/vm.example.com-qcow2' } );
    $hv_mock->redefine( domain_dir    => sub { $_[0]->{domain_dir} } );

    # An unanswerable hypervisor is the untuned case: every disk knob is gated
    # on a version, and a version we could not ask for reads as "assume not".
    # What the domain looks like when the answers do come back is the subtest
    # after this one.
    $hv_mock->redefine( libvirt_version      => sub { 0 } );
    $hv_mock->redefine( qemu_version         => sub { 0 } );
    $hv_mock->redefine( pool_fstype          => sub { 'ext2/ext3' } );
    $hv_mock->redefine( pool_takes_direct_io => sub { 1 } );
    $hv_mock->redefine(
        cloudinit_iso => sub {
            my ( $self, $domain, %files ) = @_;
            %got = %files;
            return '/pool/seed.iso';
        }
    );

    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/vm.example.com";
    Trog::HV->forget();
    Trog::HV->new( uri => 'qemu+ssh://root@hv/system', domain_dir => $dir );

    my %seed = (
        'user-data'      => "#cloud-config\n",
        'meta-data'      => "instance-id: vm.example.com\n",
        'network-config' => "version: 1\n",
    );
    my $xml = quietly( sub { domain_xml( $config, \%seed ) } );

    is_deeply( \%got, \%seed, 'all three reach the seed, as a hash' );
    like( $xml, qr{<source file='/pool/seed\.iso'/>}, 'and the ISO is attached to the domain' );
    like( $xml, qr{<name>vm\.example\.com</name>},    'which is named after the guest' );
    like( $xml, qr{<source bridge='br0'/>},           'on the outbound bridge' );
    unlike( $xml, qr/\[%/,  'with nothing of the template left in it' );
    unlike( $xml, qr/<tpm/, 'and no TPM, the hypervisor having none to make one mean anything' );

    # An emulated TPM keeps its state in a file beside the disk image, so a guest
    # is only given one where the hypervisor has hardware of its own to make that
    # file worth trusting.  See Trog::HV::has_tpm.
    $hv_mock->redefine( has_tpm => sub { 1 } );
    my $with_tpm = quietly( sub { domain_xml( $config, \%seed ) } );
    like( $with_tpm, qr{<tpm model='tpm-crb'>},                     'a hypervisor with a TPM gives its guests one' );
    like( $with_tpm, qr{<backend type='emulator' version='2\.0'/>}, 'emulated, and 2.0' );
    unlike( $with_tpm, qr/\[%/, 'still with nothing of the template left in it' );
    $hv_mock->redefine( has_tpm => sub { 0 } );

    foreach my $missing (qw{user-data meta-data network-config}) {
        my %partial = %seed;
        delete $partial{$missing};
        eval {
            quietly( sub { domain_xml( $config, \%partial ) } );
        };
        like( $@, qr/No $missing to build the cloud-init seed/, "a missing $missing is an error" );
    }
};

# --- Disk tuning: what goes in the domain depends on what will take it -------
#
# Every attribute here is gated on a version, because the fleet is not all one
# version.  These build the same guest against an old hypervisor and a new one
# and assert on the difference, which is the only part of this worth testing:
# whether the XML is any faster is not a thing a unit test can know.
sub _tuned_xml {
    my (%opts) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/vm.example.com";
    File::Slurper::Temp::write_text( "$dir/vm.example.com/mounts.txt", "raw=/dev/sdb\n" )
      if $opts{extra_disk};

    my $config = Config::Simple->new(
        _conf(
            domain => 'vm.example.com',           memory => 2048, cpus => 4,
            size   => $opts{size} // 42949672960, image  => 'https://example.test/img',
            %{ $opts{config} // {} },
        )
    );

    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine( bridge_device        => sub { 'br0' } );
    $hv_mock->redefine( has_tpm              => sub { 0 } );
    $hv_mock->redefine( pool                 => sub { 1 } );
    $hv_mock->redefine( base_image           => sub { '/pool/baseimage-qcow2' } );
    $hv_mock->redefine( create_disk          => sub { '/pool/vm.example.com-qcow2' } );
    $hv_mock->redefine( cloudinit_iso        => sub { '/pool/seed.iso' } );
    $hv_mock->redefine( domain_dir           => sub { $dir } );
    $hv_mock->redefine( libvirt_version      => sub { $opts{libvirt} } );
    $hv_mock->redefine( qemu_version         => sub { $opts{qemu} } );
    $hv_mock->redefine( pool_fstype          => sub { $opts{fstype}    // 'ext2/ext3' } );
    $hv_mock->redefine( pool_takes_direct_io => sub { $opts{direct_io} // 1 } );
    $hv_mock->redefine( zfs_version          => sub { $opts{zfs_version} } );
    $hv_mock->redefine( qemu_img_options     => sub { +{ cluster_size => 1, extended_l2 => 1 } } );

    Trog::HV->forget();
    Trog::HV->new(
        uri        => 'qemu+ssh://root@hv/system',
        domain_dir => $dir,
        %{ $opts{hv} // {} },
    );

    my %seed = (
        'user-data' => 'a', 'meta-data' => 'b', 'network-config' => 'c',
    );

    # The XML in scalar context, what it printed on the way in list context: the
    # printed half is the whole of what a downgraded cache mode tells anybody.
    my ( $xml, $said );
    {
        open( my $capture, '>', \$said ) or die $!;
        local *STDOUT = $capture;
        ($xml) = domain_xml( $config, \%seed );
        close $capture;
    }

    return wantarray ? ( $xml, $said ) : $xml;
}

# What the build said while making that domain, for the decisions whose whole
# point is telling somebody what to do about them.
sub _tuned_output {
    my (%opts) = @_;
    my ( undef, $said ) = _tuned_xml(%opts);
    return $said;
}

# libvirt encodes a version as major * 1_000_000 + minor * 1_000 + release, and
# so does everything that compares one here.  Spelled out because 0.9.8 and
# 9.8.0 are two very different numbers and only one of them is a real libvirt.
sub _libvirt { my ( $major, $minor, $release ) = @_; return ( $major * 1_000_000 ) + ( $minor * 1_000 ) + $release }

subtest 'a hypervisor from before any of this gets a domain it can still define' => sub {
    my $xml = _tuned_xml( libvirt => _libvirt( 0, 9, 0 ), qemu => _libvirt( 1, 0, 0 ) );

    unlike( $xml, qr/discard=/,          'no discard, which libvirt 1.0.6 was the first to parse' );
    unlike( $xml, qr/discard_no_unref=/, 'no discard_no_unref, which needs qemu 8.1 behind it' );
    unlike( $xml, qr/<iothreads>/,       'no iothread pool' );
    unlike( $xml, qr/iothread='/,        'and nothing assigned to one' );
    unlike( $xml, qr/queues=/,           'no virtqueue count' );
    unlike( $xml, qr/<blockio/,          'and no sector sizes announced' );

    # The one knob that is not version gated: every libvirt takes a cache mode.
    like( $xml, qr/cache='none'/, "but it still gets a cache mode, which there is no version to gate" );
    unlike( $xml, qr/\[%/, 'with nothing of the template left in it' );
};

subtest 'a middling hypervisor gets exactly the half of it that it can take' => sub {

    # libvirt 5.0 / qemu 4.0.  Not a hypothetical: that is a machine that has
    # not been rebuilt since Ubuntu 20.04, and the point of the version table is
    # that such a machine gets the knobs it has rather than all or none of them.
    my $xml = _tuned_xml( libvirt => _libvirt( 5, 0, 0 ), qemu => _libvirt( 4, 0, 0 ) );

    like( $xml, qr/discard='unmap'/, 'discard, which it has had since 1.0.6' );
    like( $xml, qr/iothread='1'/,    'an iothread, which it has had since 1.2.8' );
    like( $xml, qr/queues='4'/,      'virtqueues, since 3.9.0' );
    like( $xml, qr/<blockio/,        'and sector sizes, since 0.10.2' );

    unlike( $xml, qr/discard_no_unref=/, 'but not discard_no_unref, which wants libvirt 9.5 and qemu 8.1' );
    unlike( $xml, qr/<iothread id=/,     'and no queue mapping, which wants libvirt 10.0 and qemu 9.0' );
};

subtest 'a current hypervisor gets the lot' => sub {
    my $xml = _tuned_xml( libvirt => 10_000_000, qemu => 9_000_000 );

    like( $xml, qr/<iothreads>1<\/iothreads>/, 'an iothread, so submission is off qemu main loop' );
    like( $xml, qr/iothread='1'/,              'and the disk is on it' );
    like( $xml, qr/queues='4'/,                'one virtqueue per vcpu' );
    like( $xml, qr/discard='unmap'/,           'the guest fstrim reaches the host' );
    like( $xml, qr/discard_no_unref='on'/,     'without unrefing the cluster it just freed' );
    like(
        $xml, qr/<blockio logical_block_size='512' physical_block_size='4096'\/>/,
        'and the guest is told its sectors are 4K, before it lays a filesystem out for 512'
    );

    # A compute cost on every write, for space the guest never asked to reclaim.
    unlike( $xml, qr/detect_zeroes/, 'zero detection stays off unless it is asked for' );

    # The AIO backend is not turned on behind anybody's back.
    unlike( $xml, qr/io='io_uring'/, "and the AIO backend is left alone unless disk_io says otherwise" );

    my $asked = _tuned_xml( libvirt => 10_000_000, qemu => 9_000_000, config => { disk_io => 'io_uring' } );
    like( $asked, qr/io='io_uring'/, 'which it does when it is asked' );

    my $old = _tuned_xml( libvirt => 5_000_000, qemu => 4_000_000, config => { disk_io => 'io_uring' } );
    unlike( $old, qr/io=/, 'and not on a qemu that never had it, however loudly it is asked for' );
};

subtest 'more than one iothread is only spread where qemu can spread it' => sub {
    my %new = ( libvirt => 10_000_000, qemu => 9_000_000, config => { disk_iothreads => 4 } );

    my $xml = _tuned_xml(%new);
    like( $xml, qr/<iothreads>4<\/iothreads>/, 'the domain gets the pool it asked for' );
    like( $xml, qr/<iothread id='4'\/>/,       'and the disk maps its queues across all of it' );
    unlike( $xml, qr/<driver[^>]*iothread='/, 'so it does not also name a single one, which is mutually exclusive' );

    # qemu 8.2 has iothreads but not iothread-vq-mapping, so the pool is still
    # worth having for several disks -- one disk just cannot spread across it.
    my $unmapped = _tuned_xml( %new, qemu => 8_002_000 );
    like( $unmapped, qr/<iothreads>4<\/iothreads>/, 'a qemu without vq mapping still gets the pool' );
    like( $unmapped, qr/iothread='1'/,              'with the disk pinned to one of them' );
    unlike( $unmapped, qr/<iothread id=/, 'rather than a mapping it would refuse to start with' );
};

subtest 'the throttle is per disk, and says so when it cannot be honoured' => sub {
    my %limits = ( disk_total_iops_sec => 2000, disk_total_bytes_sec => 100_000_000 );

    my $xml = _tuned_xml( libvirt => 10_000_000, qemu => 9_000_000, config => \%limits, extra_disk => 1 );
    like( $xml, qr/<total_iops_sec>2000<\/total_iops_sec>/, 'the limit reaches the domain' );

    # Per disk rather than per domain, libvirt having no domain-wide version of
    # this: a guest with three disks can do three times what the number says.
    my @throttled = grep { index( $_, '<iotune>' ) >= 0 } split( "\n", $xml );
    is( scalar @throttled, 2, 'the throttle lands on every disk, the extra one included' );

    # A limit that is not applied is worse than no limit: somebody believes in
    # it.  So this is the one knob here that is fatal rather than skipped.
    like(
        exception { _tuned_xml( libvirt => _libvirt( 0, 9, 0 ), qemu => 9_000_000, config => \%limits ) },
        qr/need libvirt 0\.9\.8/, 'and a hypervisor too old to honour it fails the build'
    );

    like(
        exception {
            _tuned_xml(
                libvirt => 10_000_000, qemu => 9_000_000,
                config  => { disk_total_iops_sec => 2000, disk_read_iops_sec => 1000 }
            );
        },
        qr/never both/,
        'as does asking for a total and one of its halves, which libvirt refuses'
    );
};

subtest 'cache=none is offered to whatever will actually take an O_DIRECT write' => sub {

    # Asked of the filesystem, not worked out from its name: tmpfs takes one on
    # a current kernel and ZFS has since 2.3, so a list of names that cannot
    # would today have both of them wrong.
    my $tmpfs = _tuned_xml( libvirt => 10_000_000, qemu => 9_000_000, fstype => 'tmpfs', direct_io => 1 );
    like( $tmpfs, qr/cache='none'/, 'a filesystem that takes the write gets it, whatever it is called' );

    my $refused = _tuned_xml( libvirt => 10_000_000, qemu => 9_000_000, fstype => 'ext2/ext3', direct_io => 0 );
    like( $refused, qr/cache='writeback'/, 'and one that refuses gets writeback, whatever it is called' );

    # Somebody who names a mode has a reason.
    my $asked = _tuned_xml(
        libvirt => 10_000_000, qemu => 9_000_000, direct_io => 0,
        config  => { disk_cache => 'none' }
    );
    like( $asked, qr/cache='none'/, 'an explicit mode is obeyed as written either way' );
};

subtest 'a ZFS pool that refuses is told which of the two things it is' => sub {
    my %zfs = ( libvirt => 10_000_000, qemu => 9_000_000, fstype => 'zfs', direct_io => 0 );

    like(
        _tuned_output( %zfs, zfs_version => '2.2.7' ), qr/Direct I\/O arrived in 2\.3, so this wants an upgrade/,
        'a release without Direct I/O at all is told to upgrade'
    );
    like(
        _tuned_output( %zfs, zfs_version => '2.3.1' ), qr/zfs get direct/,
        'and one that has it is pointed at the pool and the dataset instead'
    );

    # 2.10 is a later release than 2.3, which a string comparison gets backwards
    # and would send somebody off to upgrade a version they already have.
    like(
        _tuned_output( %zfs, zfs_version => '2.10.0' ), qr/zfs get direct/,
        'and 2.10 is read as later than 2.3, not earlier'
    );
};

# --- Where the guest is placed, and out of which pool -------------------------
subtest 'a guest goes in the slice and the pool its hypervisor names' => sub {

    # libvirt writes <resource><partition>/machine</partition></resource> into
    # every domain when nobody says otherwise, so saying nothing has to keep
    # meaning that -- a guest that quietly escapes the slice its hypervisor
    # was given is the failure this asserts against.
    my $default = _tuned_xml( libvirt => _libvirt( 10, 0, 0 ), qemu => _libvirt( 9, 0, 0 ) );
    unlike( $default, qr/<partition>/, 'nothing written when the hypervisor names no partition' );
    like( $default, qr/<source pool='tf_disks'/, 'and the pool everything has always used' );

    # Both together, because both are named in one hypervisors.conf block and
    # they are the only two limits a guest can be held to: the pool is where a
    # filesystem quota bites, the partition is where a CPU cap does.  See
    # QUOTAS in Provisioner::Recipe::trogrunner.
    my $confined = _tuned_xml(
        libvirt => _libvirt( 10, 0, 0 ),
        qemu    => _libvirt( 9,  0, 0 ),
        hv      => { partition => '/machine/runner', pool_name => 'runner_disks' },
    );
    like( $confined, qr{<resource>\s*<partition>/machine/runner</partition>\s*</resource>}, 'the slice it was given' );
    like( $confined, qr/<source pool='runner_disks'/,                                       'out of the pool it was given, rather than the literal that used to be here' );
};

# --- Which netplan entry gets the static IP ----------------------------------
Test::NoWarnings::had_no_warnings();

done_testing;
