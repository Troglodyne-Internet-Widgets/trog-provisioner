#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

BEGIN {
    # Stub Net::EmptyPort so tests don't do real network waits
    $INC{'Net/EmptyPort.pm'} = 1;
    package Net::EmptyPort;
    sub wait_port { return 1 }
}

BEGIN {
    # Stub Net::OpenSSH::More so tests don't need real SSH
    $INC{'Net/OpenSSH/More.pm'} = 1;
    package Net::OpenSSH::More;
    sub new { bless {}, shift }
}

use Test::More;
use File::Temp qw{tempdir};
use Test::MockModule qw{strict};
use Pod::Usage();

use FindBin;
use FindBin::libs;

require_ok("$FindBin::Bin/../bin/restore")
  or BAIL_OUT('bin/restore does not load; the install is incomplete');

# Point --hvconf at nothing, so these never read the fleet file of whatever
# machine the suite happens to be running on.
my $NO_FLEET = tempdir(CLEANUP => 1) . '/hypervisors.conf';
sub main_restore { return Trog::Bin::Restore::main('--hvconf', $NO_FLEET, @_) }

# The interface is documented in POD now, and pod2usage prints that.
my $synopsis = _pod_section("$FindBin::Bin/../bin/restore", 'SYNOPSIS|OPTIONS');
like($synopsis, qr/--latest/,  'POD documents --latest');
like($synopsis, qr/--oldest/,  'POD documents --oldest');
like($synopsis, qr/--name/,    'POD documents --name');
like($synopsis, qr/--connect/, 'POD documents --connect');
like($synopsis, qr/DOMAIN/,    'POD documents the DOMAIN argument');

# No domain, and no mode, both exit non-zero with the usage.  These have to be
# real runs, since pod2usage exits rather than dying.
{
    my ($out, $rc) = _run("$FindBin::Bin/../bin/restore");
    isnt($rc, 0, 'no arguments exits non-zero');
    like($out, qr/No domain passed/, 'saying what was missing');
    like($out, qr/Usage:/,           'and printing the usage out of the POD');
}

{
    my ($out, $rc) = _run("$FindBin::Bin/../bin/restore", 'myvm.lan');
    isnt($rc, 0, 'a domain with no mode exits non-zero');
    like($out, qr/exactly one of --latest/, 'saying which flags to pick between');
}

{
    my ($out, $rc) = _run("$FindBin::Bin/../bin/restore", qw{--latest --oldest myvm.lan});
    isnt($rc, 0, 'two modes at once exits non-zero');
}

# No snapshots → dies
{
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(snapshot_names => sub { () });

    eval { main_restore('--latest', 'myvm.lan') };
    like($@, qr/No snapshots found/, 'main() dies when no snapshots exist');
}

# --name for nonexistent snapshot → dies
{
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(snapshot_names => sub { ('snap-a', 'snap-b') });

    eval { main_restore(qw{--name snap-z myvm.lan}) };
    like($@, qr/not found for myvm.lan/, 'main() dies when the named snapshot is not there');
}

# Revert fails → dies
{
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(snapshot_names   => sub { ('snap-a') });
    $hv_mock->redefine(revert_snapshot  => sub { 0 });

    eval { main_restore('--latest', 'myvm.lan') };
    like($@, qr/Failed to revert/, 'main() dies when the revert fails');
}

# Missing provision.conf → dies
{
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(snapshot_names  => sub { ('snap-a') });
    $hv_mock->redefine(revert_snapshot => sub { 1 });

    eval { main_restore(qw{--latest --domaindir /tmp/nonexistent_xyz myvm.lan}) };
    like($@, qr/No provision\.conf found/, 'main() dies when provision.conf is missing');
}

# Helper: build a minimal provision.conf in a temp dir
sub _make_conf {
    my ($dir, $domain, %params) = @_;
    my $ddir = "$dir/$domain";
    mkdir $ddir or die $!;
    open my $fh, '>', "$ddir/provision.conf" or die $!;
    for my $k (keys %params) {
        print $fh "$k=$params{$k}\n";
    }
    close $fh;
    # Create dummy key so wait_for_ssh doesn't die early
    open my $kf, '>', "$ddir/key.rsa" or die $!;
    close $kf;
    return $ddir;
}

# --latest picks last snapshot and reverts to it
{
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.5');

    my @reverted;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(snapshot_names  => sub { qw{snap-a snap-b snap-c} });
    $hv_mock->redefine(revert_snapshot => sub { @reverted = @_; return 1 });
    my $guest_mock = Test::MockModule->new('Trog::Guest');
    $guest_mock->redefine(wait_for_ssh => sub { return $_[0] });

    main_restore('--latest', '--domaindir', $tmpdir, 'myvm.lan');
    is($reverted[2], 'snap-c', '--latest picks the last snapshot');
}

# --oldest picks first snapshot
{
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.5');

    my @reverted;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(snapshot_names  => sub { qw{snap-a snap-b snap-c} });
    $hv_mock->redefine(revert_snapshot => sub { @reverted = @_; return 1 });
    my $guest_mock = Test::MockModule->new('Trog::Guest');
    $guest_mock->redefine(wait_for_ssh => sub { return $_[0] });

    main_restore('--oldest', '--domaindir', $tmpdir, 'myvm.lan');
    is($reverted[2], 'snap-a', '--oldest picks the first snapshot');
}

# --name picks the specified snapshot
{
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.5');

    my @reverted;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(snapshot_names  => sub { qw{snap-a snap-b snap-c} });
    $hv_mock->redefine(revert_snapshot => sub { @reverted = @_; return 1 });
    my $guest_mock = Test::MockModule->new('Trog::Guest');
    $guest_mock->redefine(wait_for_ssh => sub { return $_[0] });

    main_restore(qw{--name snap-b --domaindir}, $tmpdir, 'myvm.lan');
    is($reverted[1], 'myvm.lan', 'the domain is passed along');
    is($reverted[2], 'snap-b',   '--name picks the specified snapshot');
}

# wait_for_ssh called with correct user, key, ip
{
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.42');

    my $connected;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(snapshot_names  => sub { ('snap-a') });
    $hv_mock->redefine(revert_snapshot => sub { 1 });
    my $guest_mock = Test::MockModule->new('Trog::Guest');
    $guest_mock->redefine(wait_for_ssh => sub { $connected = $_[0]; return $_[0] });

    main_restore('--latest', '--domaindir', $tmpdir, 'myvm.lan');
    is($connected->ssh_user, 'ubuntu',    'the guest is reached as admin_user');
    is($connected->ssh_host, '10.0.0.42',  'at the IP from provision.conf');
    is($connected->name,     'myvm.lan',   'and knows what it is called');
    like($connected->ssh_key, qr{myvm\.lan/key\.rsa}, 'with the domain key');
}

# --connect reaches the hypervisor object
{
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.5');

    my $seen;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(snapshot_names  => sub { $seen = $_[0]->uri; return ('snap-a') });
    $hv_mock->redefine(revert_snapshot => sub { 1 });
    my $guest_mock = Test::MockModule->new('Trog::Guest');
    $guest_mock->redefine(wait_for_ssh => sub { return $_[0] });

    main_restore(qw{--latest --connect qemu+ssh://hv1/system --domaindir},
        $tmpdir, 'myvm.lan');
    is($seen, 'qemu+ssh://hv1/system', 'snapshots are looked up on the hypervisor we asked for');
}

sub _run {
    my (@cmd) = @_;
    my $out = qx{$^X @cmd 2>&1};
    return ($out, $?);
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
