#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/provision.t - bin/provision: the order it does things in, and the XML it writes

=cut

use Test::More;
use Test::Fatal qw{exception};
use IPC::Run3();
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use Test::MockModule qw{strict};
use Pod::Usage();
use Config::Simple();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }
use Trog::HV();

# No skip_all if the prereqs are missing: a suite that passes because it never
# ran is worse than one that fails.  bin/provision uses XML::Twig,
# Net::OpenSSH::More and Net::EmptyPort itself, so this explodes and tells you
# the kit is wrong rather than quietly reporting success.
my $script = "$FindBin::Bin/../bin/provision";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# --- The interface lives in POD, and pod2usage prints it ----------------------
subtest 'the POD documents the interface' => sub {
    my $synopsis = _pod_section( $script, 'SYNOPSIS|OPTIONS' );
    like( $synopsis, qr/--connect/,   'POD documents --connect' );
    like( $synopsis, qr/--domaindir/, 'POD documents --domaindir' );
    like( $synopsis, qr/--existing/,  'POD documents --existing' );
    like( $synopsis, qr/--dryrun/,    'POD documents --dryrun' );
    like( $synopsis, qr/--no-config/, 'POD documents --no-config' );
    like( $synopsis, qr/DOMAIN/,      'POD documents the DOMAIN argument' );
};

# pod2usage exits rather than dying, so this has to be a real run.
subtest 'no domain exits with the usage' => sub {
    my $out = q{};
    IPC::Run3::run3( [ $^X, $script ], \undef, \$out, \$out );
    isnt( $?, 0, 'exits non-zero' );
    like( $out, qr/No domain passed/, 'saying what was missing' );
    like( $out, qr/Usage:/,           'and printing the usage out of the POD' );
};

# --- The hypervisor comes off the config, and --connect beats it -------------
#
# Run main() as far as the hypervisor being built and then stop it, so we can
# see what it decided without letting it near a real libvirt or a real ssh.
subtest 'main() resolves the hypervisor before it touches anything' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/vm.example.com";
    File::Slurper::Temp::write_text(
        "$dir/vm.example.com/provision.conf",
        "libvirt_uri=qemu+ssh://root\@confhv/system\nips=203.0.113.10\n"
    );
    File::Slurper::Temp::write_text( "$dir/vm.example.com/users.yaml",  "users: []\n" );
    File::Slurper::Temp::write_text( "$dir/vm.example.com/data.tar.gz", "not really a tarball\n" );

    my $fakebin = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$fakebin/terraform", "#!/bin/sh\nexit 0\n" );
    chmod 0755, "$fakebin/terraform";
    local $ENV{PATH} = "$fakebin:$ENV{PATH}";

    my $no_fleet = tempdir( CLEANUP => 1 ) . '/hypervisors.conf';

    # The config generator runs first now; this test is about what happens
    # after it, so there is nothing for it to generate from.
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine( mkpath      => sub { 1 } );
    $hv_mock->redefine( file_exists => sub { 1 } );

    # no_auto: the modulino is already loaded from bin/provision, and there is
    # no Trog/Bin/Provisioner.pm for MockModule to go looking for.
    my $bin_mock = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );
    $bin_mock->redefine( mongle_network_configuration => sub { die "far enough\n" } );

    my $run = sub {
        Trog::HV->forget();
        eval { Trog::Bin::Provisioner::main( '--hvconf', $no_fleet, @_ ) };
        like( $@, qr/\Afar enough$/m, 'got as far as the hypervisor being built' );
        return Trog::HV->new();
    };

    my $hv = $run->( '--domaindir', $dir, 'vm.example.com' );
    is(
        $hv->uri, 'qemu+ssh://root@confhv/system',
        'libvirt_uri from provision.conf reaches the hypervisor object'
    );
    is( $hv->domain_dir, $dir, '--domaindir does too' );

    $hv = $run->(
        '--domaindir', $dir,
        qw{--connect qemu+ssh://root@clihv/system vm.example.com}
    );
    is( $hv->uri, 'qemu+ssh://root@clihv/system', '--connect wins over the config' );
};

# --- Adopting the state a hypervisor already had -----------------------------
# --- Adopting what libvirt already has ---------------------------------------
# --- The config generator runs first -----------------------------------------
# The warning the generator prints is the most it can do: it writes
# configuration and destroys nothing, and it runs from cron to take backups.
# This program is the one that calls clean_domain_resources, so refusing is its
# job.
subtest 'a salvage that came away empty stops the run before anything is destroyed' => sub {

    # The real generator, so this is pinned to the interface it actually
    # publishes.  A defined stub would go on passing after somebody renamed
    # salvage_gaps out from under the caller.
    require "$FindBin::Bin/../bin/new_config";    ## no critic (Modules::RequireBarewordIncludes)
    my $gen = Test::MockModule->new( 'Trog::Provisioner::Config::Generator', no_auto => 1 );

    # Nothing unreadable: every first build of a machine looks like this, and a
    # domain with no guest yet is never salvaged at all.
    $gen->redefine( salvage_gaps => sub { () } );
    is( Trog::Bin::Provisioner::refuse_on_salvage_gaps(0), 1, 'no gaps, no refusal' );

    # A directory that is on the guest and came away empty.
    $gen->redefine(
        salvage_gaps => sub {
            return ( 'vm.test' => [ { recipe => 'redis', remote => '/var/lib/redis' } ] );
        }
    );

    my $why = exception { Trog::Bin::Provisioner::refuse_on_salvage_gaps(0) };
    like( $why, qr/Refusing to rebuild/,                      'it refuses' );
    like( $why, qr{redis read nothing out of /var/lib/redis}, 'naming the recipe and the path' );
    like( $why, qr/vm[.]test/,                                'and the domain it was on' );
    like( $why, qr/--salvage-gaps-ok/,                        'and the way past it' );

    # Said out loud, and then allowed, because somebody typed the flag.
    my @said;
    my $ok = do {
        local $SIG{__WARN__} = sub { push( @said, $_[0] ) };
        Trog::Bin::Provisioner::refuse_on_salvage_gaps(1);
    };
    is( $ok, 1, 'the override lets it through' );
    like( join( q{}, @said ), qr{redis read nothing out of /var/lib/redis}, 'still saying what is being lost' );
};

# It used to stop after clean_domain_resources and after mongle_domain_xml, so a
# dry run annihilated the domain, deleted both its volumes, made a fresh disk and
# a seed, and then reported that it had applied nothing.
subtest 'a dry run applies nothing' => sub {

    # The SUT is a modulino required at runtime, so its `our` is not in scope
    # while this file compiles and perl calls the one mention a typo.
    no warnings 'once';
    local $Trog::Bin::Provisioner::dryrun = 1;
    use warnings 'once';

    my @applied;
    my $hv  = Test::MockModule->new('Trog::HV');
    my $bin = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );
    my $loc = Test::MockModule->new('Trog::Local');

    # Everything that reaches past the domain directory, named so a failure says
    # which one it was rather than that a mock died.
    $hv->redefine( domain_exists     => sub { 1 } );
    $hv->redefine( annihilate_domain => sub { push( @applied, 'annihilate_domain' ); 1 } );
    $hv->redefine( delete_volume     => sub { push( @applied, 'delete_volume' );     1 } );
    $hv->redefine( create_disk       => sub { push( @applied, 'create_disk' );       1 } );
    $hv->redefine( cloudinit_iso     => sub { push( @applied, 'cloudinit_iso' );     1 } );
    $hv->redefine( define_domain     => sub { push( @applied, 'define_domain' );     1 } );
    $hv->redefine( write_text        => sub { push( @applied, 'write_text' );        1 } );
    $hv->redefine( put_file          => sub { push( @applied, 'put_file' );          1 } );
    $hv->redefine( run_sudo          => sub { push( @applied, 'run_sudo' );          0 } );
    $loc->redefine( append_line => sub { push( @applied, 'append_line' ); 1 } );

    # The parts a dry run is supposed to do, faked out so the run reaches the end.
    $hv->redefine( virbr_device => sub { 'virbr0' } );
    $hv->redefine( virbr_ip     => sub { '192.168.122.1' } );
    $hv->redefine( sshd_port    => sub { 22 } );
    $hv->redefine( guest_mac    => sub { '52:54:00:aa:bb:cc' } );
    $hv->redefine( lease_ip     => sub { '192.168.122.50' } );
    $hv->redefine( is_local     => sub { 1 } );
    $hv->redefine( describe     => sub { 'the hypervisor' } );

    my $dir = tempdir( CLEANUP => 1 );
    $hv->redefine( domain_dir => sub { $dir } );
    mkdir "$dir/vm.test";

    # A key that is already there, which a dry run must not replace: the guest
    # that is up has its public half.
    File::Slurper::Temp::write_text( "$dir/vm.test/key.rsa",     "PRIVATE\n" );
    File::Slurper::Temp::write_text( "$dir/vm.test/key.rsa.pub", "ssh-rsa AAAA nobody\n" );
    File::Slurper::Temp::write_text( "$dir/vm.test/users.yaml",  "users:\n  - name: doge\n" );

    my $config = Config::Simple->new( syntax => 'simple' );
    $config->param( $_->[0], $_->[1] )
      for (
        [ domain      => 'vm.test' ],       [ contact_email => 'nobody@vm.test' ],
        [ ips         => '192.168.1.9' ],   [ gateway       => '192.168.1.254' ],
        [ resolvers   => '192.168.1.254' ], [ admin_user    => 'doge' ],
        [ size        => 21474836480 ],     [ cpus          => 2 ],      [ memory        => 4096 ],
        [ transfer_ip => '192.168.1.49' ],  [ transfer_user => 'doge' ], [ transfer_port => 22 ],
      );

    my ( $user, $ip ) = quietly( sub { Trog::Bin::Provisioner::provision_domain( $config, 'vm.test' ) } );

    is_deeply( \@applied, [], 'nothing outside the domain directory was touched' )
      or diag "applied: @applied";
    is( File::Slurper::read_text("$dir/vm.test/key.rsa"), "PRIVATE\n", 'the existing key is still the existing key' );

    # And it still wrote what there is to look at.
    ok( -s "$dir/vm.test/user-data", 'user-data was written' );
    ok( -s "$dir/vm.test/setup.sh",  'and the setup script' );
};

subtest 'a domain directory with no recipes is built as it stands' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my $out = quietly(
        sub {
            Trog::Bin::Provisioner::generate_config( 'vm.example.com', { domain_dir => $dir } );
        }
    );
    is( $out, 0, 'nothing to generate from, so nothing was generated' );
};

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
    my ($xml) = quietly( sub { Trog::Bin::Provisioner::mongle_domain_xml( $config, \%seed ) } );

    is_deeply( \%got, \%seed, 'all three reach the seed, as a hash' );
    like( $xml, qr{<source file='/pool/seed\.iso'/>}, 'and the ISO is attached to the domain' );
    like( $xml, qr{<name>vm\.example\.com</name>},    'which is named after the guest' );
    like( $xml, qr{<source bridge='br0'/>},           'on the outbound bridge' );
    unlike( $xml, qr/%[A-Z_]+%/, 'with every placeholder substituted' );
    unlike( $xml, qr/<tpm/,      'and no TPM, the hypervisor having none to make one mean anything' );

    # An emulated TPM keeps its state in a file beside the disk image, so a guest
    # is only given one where the hypervisor has hardware of its own to make that
    # file worth trusting.  See Trog::HV::has_tpm.
    $hv_mock->redefine( has_tpm => sub { 1 } );
    my ($with_tpm) = quietly( sub { Trog::Bin::Provisioner::mongle_domain_xml( $config, \%seed ) } );
    like( $with_tpm, qr{<tpm model='tpm-crb'>},                     'a hypervisor with a TPM gives its guests one' );
    like( $with_tpm, qr{<backend type='emulator' version='2\.0'/>}, 'emulated, and 2.0' );
    unlike( $with_tpm, qr/%[A-Z_]+%/, 'still with every placeholder substituted' );
    $hv_mock->redefine( has_tpm => sub { 0 } );

    foreach my $missing (qw{user-data meta-data network-config}) {
        my %partial = %seed;
        delete $partial{$missing};
        eval {
            quietly( sub { Trog::Bin::Provisioner::mongle_domain_xml( $config, \%partial ) } );
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
    Trog::HV->new( uri => 'qemu+ssh://root@hv/system', domain_dir => $dir );

    my %seed = (
        'user-data' => 'a', 'meta-data' => 'b', 'network-config' => 'c',
    );

    # The XML in scalar context, what it printed on the way in list context: the
    # printed half is the whole of what a downgraded cache mode tells anybody.
    my ( $xml, $said );
    {
        open( my $capture, '>', \$said ) or die $!;
        local *STDOUT = $capture;
        ($xml) = Trog::Bin::Provisioner::mongle_domain_xml( $config, \%seed );
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
    unlike( $xml, qr/%[A-Z_]+%/, 'with every placeholder substituted' );
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

# --- Which netplan entry gets the static IP ----------------------------------
subtest 'the outbound adapter is found by MAC, not by name' => sub {
    my $config = Config::Simple->new( _conf( domain => 'vm.example.com' ) );
    my $mac    = '52:54:00:AA:BB:CC';

    # cloud-init writes the MAC it matched on, so the entry identifies itself
    # whatever the guest ended up calling it.
    my $renamed = {
        network => {
            ethernets => {
                eth9   => { match => { macaddress => '52:54:00:11:22:33' }, addresses => ['10.0.0.1/24'] },
                wibble => { match => { macaddress => lc $mac },             addresses => ['203.0.113.1/24'] },
            }
        }
    };
    is(
        Trog::Bin::Provisioner::primary_adapter( $renamed, $config, $mac ), 'wibble',
        'found by MAC even under a name nothing would have guessed'
    );

    is(
        Trog::Bin::Provisioner::primary_adapter( $renamed, $config, uc $mac ), 'wibble',
        'and case does not matter'
    );

    # A guest from before any of this has no match stanza; fall back to the name.
    my $old = {
        network => {
            ethernets => {
                ens3 => { addresses => [] },
                ens4 => { addresses => ['203.0.113.1/24'] },
            }
        }
    };
    is(
        Trog::Bin::Provisioner::primary_adapter( $old, $config, $mac ), 'ens4',
        'an older guest falls back to the derived name'
    );

    # And an explicit override still wins that fallback.
    my $named = Config::Simple->new( _conf( domain => 'vm.example.com', bridge_devname => 'ens3' ) );
    is(
        Trog::Bin::Provisioner::primary_adapter( $old, $named, $mac ), 'ens3',
        'bridge_devname is still honoured'
    );

    # Nothing matching at all is an error that says what it looked for.
    my $neither = { network => { ethernets => { enp0s9 => { addresses => [] } } } };
    eval { Trog::Bin::Provisioner::primary_adapter( $neither, $config, $mac ) };
    like( $@, qr/Could not find the outbound adapter/, 'otherwise it says so' );
    like( $@, qr/enp0s9/,                              'listing what the guest does have' );

    eval { Trog::Bin::Provisioner::primary_adapter( {}, $config, $mac ) };
    like( $@, qr/No ethernets at all/, 'and a netplan with no ethernets is its own error' );
};

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

sub _pod_section {
    my ( $file, $sections ) = @_;
    open( my $fh, '>', \my $text ) or die $!;
    Pod::Usage::pod2usage(
        -input    => $file,
        -output   => $fh,
        -exitval  => 'NOEXIT',
        -verbose  => 99,
        -sections => $sections,
    );
    close $fh;
    return $text // '';
}

subtest 'the seed ISO is not ejected until cloud-init has read it' => sub {

    # The guest's MAC is derived from its name, so a rebuilt guest asks for --
    # and is given -- the lease it had last time.  libvirt's lease table keeps
    # that across a shutdown, so the address is usually already there before the
    # new guest has finished POSTing.  Ejecting the seed on the strength of it
    # pulled the ISO out seconds after start, and the guest came up with no
    # user, no keys and no netplan.  Order is the whole fix, so it is what this
    # asserts.
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/vm.example.com";
    File::Slurper::Temp::write_text( "$dir/vm.example.com/provision.conf", "admin_user=ubuntu\nips=203.0.113.10\n" );
    File::Slurper::Temp::write_text( "$dir/vm.example.com/users.yaml",     "users: []\n" );
    File::Slurper::Temp::write_text( "$dir/vm.example.com/data.tar.gz",    "not really a tarball\n" );

    my @order;

    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine( mkpath      => sub { 1 } );
    $hv_mock->redefine( file_exists => sub { 1 } );
    $hv_mock->redefine( domain_dir  => sub { $dir } );
    $hv_mock->redefine( pool_path   => sub { "$dir/disks" } );
    $hv_mock->redefine( eject_cdrom => sub { push @order, 'eject'; 1 } );

    my $guest_mock = Test::MockModule->new('Trog::Guest');
    $guest_mock->redefine( wait_for_ssh        => sub { push @order, 'ssh';       $_[0] } );
    $guest_mock->redefine( wait_for_cloud_init => sub { push @order, 'cloudinit'; 1 } );
    $guest_mock->redefine( wait_for_makefile   => sub { push @order, 'makefile';  1 } );

    my $bin_mock = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );
    $bin_mock->redefine( provision_domain => sub { push @order, 'provision'; return ( 'ubuntu', '203.0.113.10' ) } );

    Trog::HV->forget();
    my $no_fleet = tempdir( CLEANUP => 1 ) . '/hypervisors.conf';
    my $rc       = eval {
        Trog::Bin::Provisioner::main(
            '--no-config', '--hvconf', $no_fleet,
            '--domaindir', $dir,       'vm.example.com'
        );
    };
    is( $@,  '', 'main() runs to the end' ) or diag $@;
    is( $rc, 0,  'and reports success' );

    is_deeply(
        \@order, [qw{provision ssh cloudinit eject makefile}],
        'the seed comes out after cloud-init is done, not before'
    );

    my ($eject) = grep { $order[$_] eq 'eject' } 0 .. $#order;
    my ($ci)    = grep { $order[$_] eq 'cloudinit' } 0 .. $#order;
    ok( $eject > $ci, 'and never on the strength of a lease alone' );
};

done_testing;
