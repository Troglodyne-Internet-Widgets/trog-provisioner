#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper qw{write_text};
use Test::MockModule qw{strict};
use Pod::Usage();

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
    like($synopsis, qr/--tfdir/,     'POD documents --tfdir');
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

    my $tfdir = tempdir(CLEANUP => 1);

    my $no_fleet = tempdir(CLEANUP => 1) . '/hypervisors.conf';

    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(mkpath      => sub { 1 });
    $hv_mock->redefine(file_exists => sub { 1 });
    $hv_mock->redefine(get_file    => sub { write_text($_[2], '{}'); return 1 });

    # no_auto: the modulino is already loaded from bin/provision, and there is
    # no Trog/Bin/Provisioner.pm for MockModule to go looking for.
    my $bin_mock = Test::MockModule->new('Trog::Bin::Provisioner', no_auto => 1);
    $bin_mock->redefine(sync_tf_state_with_libvirt => sub { die "far enough\n" });

    my $run = sub {
        Trog::HV->forget();
        eval { Trog::Bin::Provisioner::main('--hvconf', $no_fleet, @_) };
        like($@, qr/\Afar enough$/m, 'got as far as the hypervisor being built');
        return Trog::HV->new();
    };

    my $hv = $run->('--domaindir', $dir, '--tfdir', $tfdir, 'vm.example.com');
    is($hv->uri, 'qemu+ssh://root@confhv/system',
        'libvirt_uri from provision.conf reaches the hypervisor object');
    is($hv->domain_dir, $dir,   '--domaindir does too');
    is($hv->tf_dir,     $tfdir, 'and so does --tfdir');
    ok(-d "$tfdir/config", 'the terraform config dir got made under it');

    $hv = $run->('--domaindir', $dir, '--tfdir', $tfdir,
        qw{--connect qemu+ssh://root@clihv/system vm.example.com});
    is($hv->uri, 'qemu+ssh://root@clihv/system', '--connect wins over the config');
};

# --- Adopting the state a hypervisor already had -----------------------------
subtest 'a hypervisor with its own terraform state has it adopted' => sub {
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/config";

    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(is_local      => sub { 0 });
    $hv_mock->redefine(tf_dir        => sub { $dir });
    $hv_mock->redefine(file_exists   => sub { 1 });

    my @fetched;
    $hv_mock->redefine(get_file => sub {
        my ($self, $remote, $local) = @_;
        push @fetched, [$remote, $local];
        write_text($local, '{"serial":1163}');
        return 1;
    });

    Trog::HV->forget();
    my $hv = Trog::HV->new(uri => 'qemu+ssh://root@hv1/system');

    ok(quietly(sub { Trog::Bin::Provisioner::adopt_hypervisor_state($hv) }), 'adopted');
    is_deeply($fetched[0], ['/opt/terraform/config/terraform.tfstate', "$dir/config/terraform.tfstate"],
        'from where a self-provisioned hypervisor keeps it');

    # ...and never a second time, or we would undo whatever has happened since.
    ok(!quietly(sub { Trog::Bin::Provisioner::adopt_hypervisor_state($hv) }),
        'not again once we have a state of our own');
    is(scalar @fetched, 1, 'so the local state is left alone');
};

subtest 'nothing is adopted when there is nothing to adopt' => sub {
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/config";

    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(tf_dir      => sub { $dir });
    $hv_mock->redefine(get_file    => sub { die "should not have fetched anything\n" });

    Trog::HV->forget();
    $hv_mock->redefine(is_local    => sub { 1 });
    $hv_mock->redefine(file_exists => sub { 1 });
    ok(!Trog::Bin::Provisioner::adopt_hypervisor_state(Trog::HV->new()),
        'a local hypervisor already writes where it always did');

    Trog::HV->forget();
    $hv_mock->redefine(is_local    => sub { 0 });
    $hv_mock->redefine(file_exists => sub { 0 });
    ok(!Trog::Bin::Provisioner::adopt_hypervisor_state(Trog::HV->new(uri => 'qemu+ssh://root@hv1/system')),
        'and a hypervisor with no state of its own has nothing to give us');
};

subtest 'the state goes back to the hypervisor afterwards' => sub {
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/config";
    write_text("$dir/config/terraform.tfstate", '{"serial":1164}');

    my @put;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(is_local => sub { 0 });
    $hv_mock->redefine(tf_dir   => sub { $dir });
    $hv_mock->redefine(put_file => sub { push @put, [@_[1, 2]]; return 1 });

    Trog::HV->forget();
    my $hv = Trog::HV->new(uri => 'qemu+ssh://root@hv1/system');

    ok(quietly(sub { Trog::Bin::Provisioner::return_hypervisor_state($hv) }), 'returned');
    is_deeply($put[0], ["$dir/config/terraform.tfstate", '/opt/terraform/config/terraform.tfstate'],
        'to where the hypervisor keeps its own');

    # A dry run changed nothing, so it has nothing to hand back.
    no warnings 'once';
    local $Trog::Bin::Provisioner::dryrun = 1;
    ok(!quietly(sub { Trog::Bin::Provisioner::return_hypervisor_state($hv) }), 'not after a dryrun');
    is(scalar @put, 1, 'and nothing was sent');
};

# --- Adopting what libvirt already has ---------------------------------------
subtest 'import blocks are emitted only for things that exist' => sub {
    is(Trog::Bin::Provisioner::_import_block('libvirt_volume.image_base', undef, 'base image'), '',
        'nothing to import means no block, so terraform creates it');
    is(Trog::Bin::Provisioner::_import_block('libvirt_volume.image_base', '', 'base image'), '',
        'and an empty id is the same as none');

    my $block = quietly(sub {
        Trog::Bin::Provisioner::_import_block('libvirt_volume.image_base',
            '/opt/terraform/disks/baseimage-qcow2', 'base image');
    });

    like($block, qr/\bimport \{/,                             'an existing one gets an import block');
    like($block, qr/to = libvirt_volume\.image_base/,         'addressed to the right resource');
    like($block, qr{id = "/opt/terraform/disks/baseimage-qcow2"}, 'with the volume key as the id');
};

sub quietly {
    my ($code) = @_;
    open(my $capture, '>', \my $out) or die $!;
    my $result = do { local *STDOUT = $capture; $code->() };
    close $capture;
    return $result;
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
