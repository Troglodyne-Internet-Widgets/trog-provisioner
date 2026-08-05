#!/usr/bin/env perl
use strict;
use warnings;

BEGIN {
    # Stub File::Which
    $INC{'File/Which.pm'} = 1;
    package File::Which;
    use Exporter 'import';
    our @EXPORT_OK = qw{which};
    sub which { return '/usr/bin/virsh' }
}

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

use Test::More tests => 19;
use File::Temp qw{tempdir};

require './bin/restore';

# usage() mentions expected flags
my $usage = Trog::Bin::Restore::usage();
like($usage, qr/--latest/,  'usage mentions --latest');
like($usage, qr/--oldest/,  'usage mentions --oldest');
like($usage, qr/--name/,    'usage mentions --name');
like($usage, qr/DOMAIN/,    'usage mentions DOMAIN');

# No domain → dies with usage
eval { Trog::Bin::Restore::main() };
like($@, qr/Usage:/, 'main() with no args dies with usage');

# No mode → dies with usage
eval { Trog::Bin::Restore::main('myvm.lan') };
like($@, qr/Usage:/, 'main() with domain but no mode dies with usage');

# Multiple modes → dies with usage
eval { Trog::Bin::Restore::main('--latest', '--oldest', 'myvm.lan') };
like($@, qr/Usage:/, 'main() with multiple mode flags dies with usage');

# No snapshots → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Restore::_virsh_snap_list = sub { () };

    eval { Trog::Bin::Restore::main('--latest', 'myvm.lan') };
    like($@, qr/No snapshots found/, 'main() dies when no snapshots exist');
}

# --name for nonexistent snapshot → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Restore::_virsh_snap_list = sub { ('snap-a', 'snap-b') };

    eval { Trog::Bin::Restore::main('--name', 'snap-z', 'myvm.lan') };
    like($@, qr/not found for myvm.lan/, 'main() dies when named snapshot not found');
}

# virsh revert fails → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Restore::_virsh_snap_list   = sub { ('snap-a') };
    local *Trog::Bin::Restore::_virsh_snap_revert = sub { 1 };

    eval { Trog::Bin::Restore::main('--latest', 'myvm.lan') };
    like($@, qr/Failed to revert/, 'main() dies when virsh revert fails');
}

# Missing provision.conf → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Restore::_virsh_snap_list   = sub { ('snap-a') };
    local *Trog::Bin::Restore::_virsh_snap_revert = sub { 0 };

    eval { Trog::Bin::Restore::main('--latest', '--domaindir', '/tmp/nonexistent_xyz', 'myvm.lan') };
    like($@, qr/No provision\.conf found/, 'main() dies when provision.conf missing');
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
    no warnings 'redefine';
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.5');

    my @reverted;
    local *Trog::Bin::Restore::_virsh_snap_list   = sub { ('snap-a', 'snap-b', 'snap-c') };
    local *Trog::Bin::Restore::_virsh_snap_revert = sub { @reverted = @_; return 0 };
    local *Trog::Bin::Restore::wait_for_ssh       = sub { 1 };

    Trog::Bin::Restore::main('--latest', '--domaindir', $tmpdir, 'myvm.lan');
    is($reverted[1], 'snap-c', '--latest picks the last snapshot');
}

# --oldest picks first snapshot
{
    no warnings 'redefine';
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.5');

    my @reverted;
    local *Trog::Bin::Restore::_virsh_snap_list   = sub { ('snap-a', 'snap-b', 'snap-c') };
    local *Trog::Bin::Restore::_virsh_snap_revert = sub { @reverted = @_; return 0 };
    local *Trog::Bin::Restore::wait_for_ssh       = sub { 1 };

    Trog::Bin::Restore::main('--oldest', '--domaindir', $tmpdir, 'myvm.lan');
    is($reverted[1], 'snap-a', '--oldest picks the first snapshot');
}

# --name picks the specified snapshot
{
    no warnings 'redefine';
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.5');

    my @reverted;
    local *Trog::Bin::Restore::_virsh_snap_list   = sub { ('snap-a', 'snap-b', 'snap-c') };
    local *Trog::Bin::Restore::_virsh_snap_revert = sub { @reverted = @_; return 0 };
    local *Trog::Bin::Restore::wait_for_ssh       = sub { 1 };

    Trog::Bin::Restore::main('--name', 'snap-b', '--domaindir', $tmpdir, 'myvm.lan');
    is($reverted[1], 'snap-b', '--name picks the specified snapshot');
}

# wait_for_ssh called with correct user, key, ip
{
    no warnings 'redefine';
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.42');

    my @ssh_args;
    local *Trog::Bin::Restore::_virsh_snap_list   = sub { ('snap-a') };
    local *Trog::Bin::Restore::_virsh_snap_revert = sub { 0 };
    local *Trog::Bin::Restore::wait_for_ssh       = sub { @ssh_args = @_; return 1 };

    Trog::Bin::Restore::main('--latest', '--domaindir', $tmpdir, 'myvm.lan');
    is($ssh_args[0], 'ubuntu',                       'wait_for_ssh called with admin_user');
    is($ssh_args[2], '10.0.0.42',                    'wait_for_ssh called with IP from provision.conf');
    like($ssh_args[1], qr{myvm\.lan/key\.rsa},       'wait_for_ssh called with domain key path');
}

# virsh revert receives correct --snapshotname and --running flags
{
    no warnings 'redefine';
    my $tmpdir = tempdir(CLEANUP => 1);
    _make_conf($tmpdir, 'myvm.lan', admin_user => 'ubuntu', ips => '10.0.0.5');

    my @cmd_args;
    local *Trog::Bin::Restore::_virsh_snap_list   = sub { ('snap-x') };
    local *Trog::Bin::Restore::_virsh_snap_revert = sub { @cmd_args = @_; return 0 };
    local *Trog::Bin::Restore::wait_for_ssh       = sub { 1 };

    Trog::Bin::Restore::main('--latest', '--domaindir', $tmpdir, 'myvm.lan');
    is($cmd_args[0], 'myvm.lan',  '_virsh_snap_revert receives domain');
    is($cmd_args[1], 'snap-x',    '_virsh_snap_revert receives snapshot name');
}
