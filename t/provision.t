#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper qw{write_text};
use Test::MockModule qw{strict};
use Pod::Usage();
use Config::Simple();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }
use Trog::HV();

# No skip_all if the prereqs are missing: a suite that passes because it never
# ran is worse than one that fails.  bin/provision uses XML::Twig,
# Net::OpenSSH::More and Net::EmptyPort itself, so this explodes and tells you
# the kit is wrong rather than quietly reporting success.
my $script = "$FindBin::Bin/../bin/provision";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# --- The interface lives in POD, and pod2usage prints it ----------------------
subtest 'the POD documents the interface' => sub {
    my $synopsis = _pod_section($script, 'SYNOPSIS|OPTIONS');
    like($synopsis, qr/--connect/,   'POD documents --connect');
    like($synopsis, qr/--domaindir/, 'POD documents --domaindir');
    like($synopsis, qr/--existing/,  'POD documents --existing');
    like($synopsis, qr/--dryrun/,    'POD documents --dryrun');
    like($synopsis, qr/--no-config/, 'POD documents --no-config');
    like($synopsis, qr/DOMAIN/,      'POD documents the DOMAIN argument');
};

# pod2usage exits rather than dying, so this has to be a real run.
subtest 'no domain exits with the usage' => sub {
    my $out = qx{$^X $script 2>&1};
    isnt($?, 0, 'exits non-zero');
    like($out, qr/No domain passed/, 'saying what was missing');
    like($out, qr/Usage:/,           'and printing the usage out of the POD');
};

# --- The hypervisor comes off the config, and --connect beats it -------------
#
# Run main() as far as the hypervisor being built and then stop it, so we can
# see what it decided without letting it near a real libvirt or a real ssh.
subtest 'main() resolves the hypervisor before it touches anything' => sub {
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/vm.example.com";
    write_text("$dir/vm.example.com/provision.conf",
        "libvirt_uri=qemu+ssh://root\@confhv/system\nips=203.0.113.10\n");
    write_text("$dir/vm.example.com/users.yaml",  "users: []\n");
    write_text("$dir/vm.example.com/data.tar.gz", "not really a tarball\n");

    my $fakebin = tempdir(CLEANUP => 1);
    write_text("$fakebin/terraform", "#!/bin/sh\nexit 0\n");
    chmod 0755, "$fakebin/terraform";
    local $ENV{PATH} = "$fakebin:$ENV{PATH}";

    my $no_fleet = tempdir(CLEANUP => 1) . '/hypervisors.conf';

    # The config generator runs first now; this test is about what happens
    # after it, so there is nothing for it to generate from.
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(mkpath      => sub { 1 });
    $hv_mock->redefine(file_exists => sub { 1 });

    # no_auto: the modulino is already loaded from bin/provision, and there is
    # no Trog/Bin/Provisioner.pm for MockModule to go looking for.
    my $bin_mock = Test::MockModule->new('Trog::Bin::Provisioner', no_auto => 1);
    $bin_mock->redefine(mongle_network_configuration => sub { die "far enough\n" });

    my $run = sub {
        Trog::HV->forget();
        eval { Trog::Bin::Provisioner::main('--hvconf', $no_fleet, @_) };
        like($@, qr/\Afar enough$/m, 'got as far as the hypervisor being built');
        return Trog::HV->new();
    };

    my $hv = $run->('--domaindir', $dir, 'vm.example.com');
    is($hv->uri, 'qemu+ssh://root@confhv/system',
        'libvirt_uri from provision.conf reaches the hypervisor object');
    is($hv->domain_dir, $dir,   '--domaindir does too');

    $hv = $run->('--domaindir', $dir,
        qw{--connect qemu+ssh://root@clihv/system vm.example.com});
    is($hv->uri, 'qemu+ssh://root@clihv/system', '--connect wins over the config');
};

# --- Adopting the state a hypervisor already had -----------------------------
# --- Adopting what libvirt already has ---------------------------------------
# --- The config generator runs first -----------------------------------------
subtest 'a domain directory with no recipes is built as it stands' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $out = quietly(sub {
        Trog::Bin::Provisioner::generate_config('vm.example.com', { domain_dir => $dir });
    });
    is($out, 0, 'nothing to generate from, so nothing was generated');
};

# --- The cloud-init seed --------------------------------------------------
#
# These three go to Trog::HV::cloudinit_iso as a hash.  Passing it anything
# else -- a single string, say -- is an odd number of elements in a hash
# assignment, which is a warning and then a seed with no files in it.
subtest 'the seed is built from all three NoCloud files' => sub {
    my $config = Config::Simple->new(_conf(domain => 'vm.example.com', memory => 2048,
        cpus => 2, size => 42949672960, image => 'https://example.test/img'));

    my %got;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(bridge_device => sub { 'br0' });
    $hv_mock->redefine(pool          => sub { 1 });
    $hv_mock->redefine(base_image    => sub { '/pool/baseimage-qcow2' });
    $hv_mock->redefine(create_disk   => sub { '/pool/vm.example.com-qcow2' });
    $hv_mock->redefine(domain_dir    => sub { $_[0]->{domain_dir} });
    $hv_mock->redefine(cloudinit_iso => sub {
        my ($self, $domain, %files) = @_;
        %got = %files;
        return '/pool/seed.iso';
    });

    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/vm.example.com";
    Trog::HV->forget();
    Trog::HV->new(uri => 'qemu+ssh://root@hv/system', domain_dir => $dir);

    my %seed = (
        'user-data'      => "#cloud-config\n",
        'meta-data'      => "instance-id: vm.example.com\n",
        'network-config' => "version: 1\n",
    );
    my ($xml) = quietly(sub { Trog::Bin::Provisioner::mongle_domain_xml($config, \%seed) });

    is_deeply(\%got, \%seed, 'all three reach the seed, as a hash');
    like($xml, qr{<source file='/pool/seed\.iso'/>}, 'and the ISO is attached to the domain');
    like($xml, qr{<name>vm\.example\.com</name>},     'which is named after the guest');
    like($xml, qr{<source bridge='br0'/>},            'on the outbound bridge');
    unlike($xml, qr/%[A-Z_]+%/,                       'with every placeholder substituted');

    foreach my $missing (qw{user-data meta-data network-config}) {
        my %partial = %seed;
        delete $partial{$missing};
        eval { quietly(sub { Trog::Bin::Provisioner::mongle_domain_xml($config, \%partial) }) };
        like($@, qr/No $missing to build the cloud-init seed/, "a missing $missing is an error");
    }
};

# --- Which netplan entry gets the static IP ----------------------------------
subtest 'the outbound adapter is found by MAC, not by name' => sub {
    my $config = Config::Simple->new(_conf(domain => 'vm.example.com'));
    my $mac    = '52:54:00:AA:BB:CC';

    # cloud-init writes the MAC it matched on, so the entry identifies itself
    # whatever the guest ended up calling it.
    my $renamed = { network => { ethernets => {
        eth9  => { match => { macaddress => '52:54:00:11:22:33' }, addresses => ['10.0.0.1/24'] },
        wibble=> { match => { macaddress => lc $mac },             addresses => ['203.0.113.1/24'] },
    } } };
    is(Trog::Bin::Provisioner::primary_adapter($renamed, $config, $mac), 'wibble',
        'found by MAC even under a name nothing would have guessed');

    is(Trog::Bin::Provisioner::primary_adapter($renamed, $config, uc $mac), 'wibble',
        'and case does not matter');

    # A guest from before any of this has no match stanza; fall back to the name.
    my $old = { network => { ethernets => {
        ens3 => { addresses => [] },
        ens4 => { addresses => ['203.0.113.1/24'] },
    } } };
    is(Trog::Bin::Provisioner::primary_adapter($old, $config, $mac), 'ens4',
        'an older guest falls back to the derived name');

    # And an explicit override still wins that fallback.
    my $named = Config::Simple->new(_conf(domain => 'vm.example.com', bridge_devname => 'ens3'));
    is(Trog::Bin::Provisioner::primary_adapter($old, $named, $mac), 'ens3',
        'bridge_devname is still honoured');

    # Nothing matching at all is an error that says what it looked for.
    my $neither = { network => { ethernets => { enp0s9 => { addresses => [] } } } };
    eval { Trog::Bin::Provisioner::primary_adapter($neither, $config, $mac) };
    like($@, qr/Could not find the outbound adapter/, 'otherwise it says so');
    like($@, qr/enp0s9/,                              'listing what the guest does have');

    eval { Trog::Bin::Provisioner::primary_adapter({}, $config, $mac) };
    like($@, qr/No ethernets at all/, 'and a netplan with no ethernets is its own error');
};

sub _conf {
    my (%params) = @_;
    my $dir = tempdir(CLEANUP => 1);
    write_text("$dir/provision.conf", join('', map { "$_=$params{$_}\n" } sort keys %params));
    return "$dir/provision.conf";
}

sub quietly {
    my ($code) = @_;
    open(my $capture, '>', \my $out) or die $!;
    my @result = do { local *STDOUT = $capture; $code->() };
    close $capture;
    return wantarray ? @result : $result[0];
}

sub _pod_section {
    my ($file, $sections) = @_;
    open(my $fh, '>', \my $text) or die $!;
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
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/vm.example.com";
    write_text("$dir/vm.example.com/provision.conf", "admin_user=ubuntu\nips=203.0.113.10\n");
    write_text("$dir/vm.example.com/users.yaml", "users: []\n");
    write_text("$dir/vm.example.com/data.tar.gz", "not really a tarball\n");

    my @order;

    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(mkpath      => sub { 1 });
    $hv_mock->redefine(file_exists => sub { 1 });
    $hv_mock->redefine(domain_dir  => sub { $dir });
    $hv_mock->redefine(pool_path   => sub { "$dir/disks" });
    $hv_mock->redefine(eject_cdrom => sub { push @order, 'eject'; 1 });

    my $guest_mock = Test::MockModule->new('Trog::Guest');
    $guest_mock->redefine(wait_for_ssh        => sub { push @order, 'ssh';      $_[0] });
    $guest_mock->redefine(wait_for_cloud_init => sub { push @order, 'cloudinit'; 1 });
    $guest_mock->redefine(wait_for_makefile   => sub { push @order, 'makefile';  1 });

    my $bin_mock = Test::MockModule->new('Trog::Bin::Provisioner', no_auto => 1);
    $bin_mock->redefine(provision_domain => sub { push @order, 'provision'; return ('ubuntu', '203.0.113.10') });

    Trog::HV->forget();
    my $no_fleet = tempdir(CLEANUP => 1) . '/hypervisors.conf';
    my $rc = eval {
        Trog::Bin::Provisioner::main('--no-config', '--hvconf', $no_fleet,
            '--domaindir', $dir, 'vm.example.com');
    };
    is($@, '', 'main() runs to the end') or diag $@;
    is($rc, 0, 'and reports success');

    is_deeply(\@order, [qw{provision ssh cloudinit eject makefile}],
        'the seed comes out after cloud-init is done, not before');

    my ($eject) = grep { $order[$_] eq 'eject' } 0 .. $#order;
    my ($ci)    = grep { $order[$_] eq 'cloudinit' } 0 .. $#order;
    ok($eject > $ci, 'and never on the strength of a lease alone');
};

done_testing;
