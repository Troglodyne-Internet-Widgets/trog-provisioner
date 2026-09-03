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
