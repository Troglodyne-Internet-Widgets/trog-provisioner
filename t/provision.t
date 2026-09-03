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

done_testing;
