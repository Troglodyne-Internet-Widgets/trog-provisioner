#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper qw{write_text};
use Test::MockModule qw{strict};
use Config::Simple();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }
use Trog::HV();
use Trog::Hypervisors();

my $GB = 1024 * 1024 * 1024;

# A hypervisors.conf with two machines in it.
sub fleet_file {
    my (%extra) = @_;
    $extra{$_} //= '' for qw{hv1 hv2};
    my $dir = tempdir(CLEANUP => 1);
    write_text("$dir/hypervisors.conf", <<"CONF");
[hv1]
libvirt_uri=qemu+ssh://root\@hv1.example.net/system
bridge_device=br0
reserve_memory=4096
max_guests=20
$extra{hv1}

[hv2]
libvirt_uri=qemu+ssh://root\@hv2.example.net/system
$extra{hv2}
CONF
    return "$dir/hypervisors.conf";
}

sub guest_conf {
    my (%params) = @_;
    my $dir = tempdir(CLEANUP => 1);
    write_text("$dir/provision.conf", join('', map { "$_=$params{$_}\n" } sort keys %params));
    return Config::Simple->new("$dir/provision.conf");
}

# Capacity comes from libvirt, so hand Trog::HV a made-up one.
sub with_capacity {
    my (%by_name) = @_;
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(capacity => sub {
        my ($self) = @_;
        my $c = $by_name{ $self->name // 'local' }
          or die "no capacity configured for " . ($self->name // 'local') . "\n";
        die "$c\n" if !ref $c;    # a string stands for an unreachable machine
        return $c;
    });
    return $mock;
}

# place() reports what it chose; tests don't need to see it.
sub quietly {
    my ($code) = @_;
    open(my $capture, '>', \my $out) or die $!;
    my @result = do { local *STDOUT = $capture; $code->() };
    close $capture;
    return wantarray ? @result : $result[0];
}

sub capacity {
    my (%o) = @_;
    return {
        memory_mb        => $o{memory_mb}        // 65536,
        memory_committed => $o{memory_committed} // 0,
        memory_free      => $o{memory_free}      // 32768,
        cpus             => $o{cpus}             // 16,
        cpus_allocatable => $o{cpus_allocatable} // 64,
        cpus_committed   => $o{cpus_committed}   // 0,
        cpus_free        => $o{cpus_free}        // 32,
        disk_free        => $o{disk_free}        // 500 * $GB,
        guests           => $o{guests}           // 3,
    };
}

# --- Reading the file ---------------------------------------------------------
subtest 'no hypervisors.conf means no fleet' => sub {
    my $fleet = Trog::Hypervisors->load('/tmp/nonexistent_xyz/hypervisors.conf');
    ok(!$fleet->configured, 'not configured');
    is_deeply([$fleet->names], [], 'and it names nobody');

    ok(!Trog::Hypervisors->load(undef)->configured, 'an undef path is the same thing');
};

subtest 'a fleet is read in file order' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());
    ok($fleet->configured, 'configured');
    is_deeply([$fleet->names], [qw{hv1 hv2}], 'both, in order');

    my $hv1 = $fleet->hypervisor('hv1');
    is($hv1->name,           'hv1',                                  'name');
    is($hv1->uri,            'qemu+ssh://root@hv1.example.net/system', 'uri');
    is($hv1->bridge_device,  'br0',                                  'bridge_device, so no probing');
    is($hv1->reserve_memory, 4096,                                   'reserve_memory');
    is($hv1->max_guests,     20,                                     'max_guests');

    is($fleet->hypervisor('hv2')->reserve_memory, 2048, 'unset limits fall back to the defaults');
    is($fleet->hypervisor('hv2')->cpu_overcommit, 4,    'including the cpu overcommit ratio');

    is($fleet->hypervisor('hv1'), $hv1, 'built once and kept');
};

subtest 'a name the file does not have is an error' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());
    eval { $fleet->hypervisor('hv3') };
    like($@, qr/No hypervisor named 'hv3'/, 'dies');
    like($@, qr/hv1, hv2/,                  'and says what there is');
};

subtest 'a file with no blocks is an error' => sub {
    my $dir = tempdir(CLEANUP => 1);
    write_text("$dir/hypervisors.conf", "libvirt_uri=qemu:///system\n");
    eval { Trog::Hypervisors->load("$dir/hypervisors.conf") };
    like($@, qr/names no hypervisors/, 'dies rather than silently finding nothing');
};

# --- Finding a guest that already exists -------------------------------------
subtest 'hosting asks each hypervisor' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(domain_exists => sub { $_[0]->name eq 'hv2' ? 1 : 0 });

    my $found = $fleet->hosting('vm.example.com');
    is($found && $found->name, 'hv2', 'the one that has it');

    $mock->redefine(domain_exists => sub { 0 });
    is($fleet->hosting('vm.example.com'), undef, 'undef when nobody does');
};

subtest 'an unreachable hypervisor is warned about, not fatal' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(domain_exists => sub {
        die "connection refused\n" if $_[0]->name eq 'hv1';
        return 1;
    });

    my @warnings;
    my $found = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $fleet->hosting('vm.example.com');
    };

    is($found && $found->name, 'hv2', 'the reachable one still answers');
    like(join('', @warnings), qr/hv1/,                 'and we said which one we could not ask');
    like(join('', @warnings), qr/connection refused/,  'including why');
};

# --- Placement ----------------------------------------------------------------
subtest 'place picks the roomiest that fits' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());
    my $mock  = with_capacity(
        hv1 => capacity(memory_free => 8192,  disk_free => 100 * $GB),
        hv2 => capacity(memory_free => 40000, disk_free => 900 * $GB),
    );

    my $chosen = quietly(sub { $fleet->place('vm.example.com', memory_mb => 4096, cpus => 2, disk_bytes => 40 * $GB) });
    is($chosen->name, 'hv2', 'the emptier one');
};

subtest 'placement is by the tightest resource, not the roomiest' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());

    # hv1 has more memory free; hv2 has far more disk.  A guest wanting a big
    # disk belongs on hv2 even though hv1 looks better on RAM alone.
    my $mock = with_capacity(
        hv1 => capacity(memory_free => 60000, memory_mb => 65536, disk_free => 60 * $GB),
        hv2 => capacity(memory_free => 20000, memory_mb => 65536, disk_free => 4000 * $GB),
    );

    my $chosen = quietly(sub { $fleet->place('big.example.com', memory_mb => 4096, cpus => 2, disk_bytes => 50 * $GB) });
    is($chosen->name, 'hv2', 'the one that will not be nearly full afterwards');
};

subtest 'nowhere to put it is an error that says why' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());
    my $mock  = with_capacity(
        hv1 => capacity(memory_free => 512, guests => 20),
        hv2 => capacity(memory_free => 512, disk_free => 1 * $GB),
    );

    eval { $fleet->place('vm.example.com', memory_mb => 8192, cpus => 2, disk_bytes => 40 * $GB) };
    like($@, qr/Nowhere to put vm\.example\.com/, 'refuses');
    like($@, qr/hv1: needs 8192MB of memory, 512MB free/, 'naming what hv1 was short of');
    like($@, qr/hv1: already has 20 guests/,              'and that it is full');
    like($@, qr/hv2: needs 40GB of disk/,                 'and what hv2 was short of');
};

subtest 'an unreachable hypervisor is reported as such, not skipped silently' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());
    my $mock  = with_capacity(hv1 => 'libvirt says no', hv2 => capacity(memory_free => 512));

    eval { $fleet->place('vm.example.com', memory_mb => 8192, cpus => 2, disk_bytes => 1 * $GB) };
    like($@, qr/hv1: unreachable -- libvirt says no/, 'named, with the reason');
};

# --- select_for ---------------------------------------------------------------
subtest 'a guest that already exists stays where it is' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(domain_exists => sub { $_[0]->name eq 'hv1' ? 1 : 0 });
    $mock->redefine(capacity      => sub { die "placement should not have been asked\n" });

    my $hv = quietly(sub { $fleet->select_for('vm.example.com', guest_conf(memory => 4096, cpus => 2, size => 40 * $GB)) });
    is($hv->name, 'hv1', 'found rather than placed');
    is(Trog::HV->new()->name, 'hv1', 'and it became the current hypervisor');
};

subtest 'provision.conf can pin a guest to a hypervisor' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(domain_exists => sub { 0 });
    $mock->redefine(capacity      => sub { capacity() });

    my $conf = guest_conf(memory => 4096, cpus => 2, size => 40 * $GB, hypervisor => 'hv2');
    my $hv = $fleet->select_for('vm.example.com', $conf);
    is($hv->name, 'hv2', 'pinned where it was told');
};

subtest 'a pin to a hypervisor that cannot take it is an error' => sub {
    my $fleet = Trog::Hypervisors->load(fleet_file());

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(domain_exists => sub { 0 });
    $mock->redefine(capacity      => sub { capacity(memory_free => 128) });

    my $conf = guest_conf(memory => 4096, cpus => 2, size => 40 * $GB, hypervisor => 'hv2');
    eval { $fleet->select_for('vm.example.com', $conf) };
    like($@, qr/pinned to hv2, which cannot take it/, 'refuses rather than placing it elsewhere');
    like($@, qr/needs 4096MB of memory/,              'and says what it was short of');
};

# --- find ---------------------------------------------------------------------
subtest 'find' => sub {
    my $path = fleet_file();

    Trog::HV->forget();
    my $explicit = Trog::Hypervisors->find('vm.example.com',
        uri => 'qemu+ssh://root@elsewhere/system', hvconf => $path);
    is($explicit->uri, 'qemu+ssh://root@elsewhere/system', '--connect skips the fleet entirely');

    Trog::HV->forget();
    my $no_fleet = Trog::Hypervisors->find('vm.example.com',
        hvconf => '/tmp/nonexistent_xyz/hypervisors.conf', config => undef);
    ok($no_fleet->is_local, 'with no fleet we are back to the local hypervisor');

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(domain_exists => sub { $_[0]->name eq 'hv2' ? 1 : 0 });

    Trog::HV->forget();
    my $found = quietly(sub { Trog::Hypervisors->find('vm.example.com', hvconf => $path) });
    is($found->name, 'hv2', 'found on the one that has it');

    $mock->redefine(domain_exists => sub { 0 });
    Trog::HV->forget();
    eval { Trog::Hypervisors->find('gone.example.com', hvconf => $path) };
    like($@, qr/has a guest called gone\.example\.com/, 'a guest on none of them is an error');
    like($@, qr/Looked on: hv1, hv2/,                   'saying where we looked');
};

# --- Capacity arithmetic, against a stand-in libvirt --------------------------
subtest 'capacity counts what is committed, not what is used' => sub {
    Trog::HV->forget();
    my $hv = Trog::HV->candidate(uri => 'qemu+ssh://hv/system', name => 'hv1', reserve_memory => 2048, reserve_cpus => 2);

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(vmm       => sub { FakeVMM->new() });
    $mock->redefine(pool_free => sub { 200 * $GB });

    my $have = $hv->capacity;
    is($have->{memory_mb},        32768, 'physical memory in MB');
    is($have->{memory_committed}, 12288, 'the sum of what guests may grow into, idle or not');
    is($have->{memory_free},      32768 - 12288 - 2048, 'free is physical less committed less the reserve');
    is($have->{cpus},             8,  'physical CPUs');
    is($have->{cpus_allocatable}, 32, 'times the overcommit ratio');
    is($have->{cpus_committed},   6,  'vCPUs of running guests only');
    is($have->{cpus_free},        32 - 6 - 2, 'free CPUs after the reserve');
    is($have->{guests},           3,  'domains, running or not');

    is($hv->capacity, $have, 'cached, so we ask libvirt once');
};

subtest 'shortfalls and headroom' => sub {
    Trog::HV->forget();
    my $hv = Trog::HV->candidate(uri => 'qemu+ssh://hv/system', name => 'hv1');

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(capacity => sub { capacity(memory_free => 8192, cpus_free => 4, disk_free => 100 * $GB) });

    is_deeply([$hv->shortfalls(memory_mb => 4096, cpus => 2, disk_bytes => 50 * $GB)], [],
        'a guest that fits has nothing wrong with it');

    my @reasons = $hv->shortfalls(memory_mb => 99999, cpus => 99, disk_bytes => 900 * $GB);
    is(scalar @reasons, 3, 'one reason per resource it is short of');
    like($reasons[0], qr/memory/, 'memory');
    like($reasons[1], qr/vCPUs/,  'cpus');
    like($reasons[2], qr/disk/,   'disk');

    my $roomy  = $hv->headroom(memory_mb => 1,    cpus => 1, disk_bytes => 1 * $GB);
    my $snug   = $hv->headroom(memory_mb => 8000, cpus => 4, disk_bytes => 99 * $GB);
    cmp_ok($roomy, '>', $snug, 'a small guest leaves more headroom than one that just fits');
    cmp_ok($snug,  '>=', 0,    'and headroom never goes negative');
};

# A stand-in for a libvirt connection.
{
    package FakeVMM;
    use strict;
    use warnings FATAL => 'all';

    sub new { return bless {}, shift }
    sub get_node_info { return { memory => 32768 * 1024, cpus => 8, model => 'x86_64' } }

    sub list_all_domains {
        return (
            FakeDomain->new( maxMem => 4096 * 1024, nrVirtCpu => 2, active => 1 ),
            FakeDomain->new( maxMem => 4096 * 1024, nrVirtCpu => 4, active => 1 ),
            # Shut off, so its memory is still committed but its vCPUs are not.
            FakeDomain->new( maxMem => 4096 * 1024, nrVirtCpu => 8, active => 0 ),
        );
    }
}

{
    package FakeDomain;
    use strict;
    use warnings FATAL => 'all';

    sub new { my ($class, %o) = @_; return bless {%o}, $class }
    sub get_info  { my ($s) = @_; return { maxMem => $s->{maxMem}, nrVirtCpu => $s->{nrVirtCpu} } }
    sub is_active { return $_[0]->{active} }
}

done_testing;
