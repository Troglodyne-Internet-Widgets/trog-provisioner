#!/usr/bin/env perl
use strict;
use warnings;

# Stub File::Which before loading the script so we don't need it installed.
BEGIN {
    $INC{'File/Which.pm'} = 1;
    package File::Which;
    use Exporter 'import';
    our @EXPORT_OK = qw{which};
    sub which { return '/usr/bin/virsh' }
}

use Test::More tests => 18;

# Load bin/snapshot as a library (caller returns true so main() is skipped).
require './bin/snapshot';

# -------------------------------------------------------------------------
# _default_snap_name — must look like YYYYMMDD-HHMMSS
# -------------------------------------------------------------------------
my $snap_name = Trog::Bin::Snapshot::_default_snap_name();
like($snap_name, qr/^\d{8}-\d{6}$/, '_default_snap_name has expected format');

# -------------------------------------------------------------------------
# usage() — must mention the expected flags
# -------------------------------------------------------------------------
my $usage = Trog::Bin::Snapshot::usage();
like($usage, qr/--create/,      'usage mentions --create');
like($usage, qr/--list/,        'usage mentions --list');
like($usage, qr/--restore/,     'usage mentions --restore');
like($usage, qr/--delete/,      'usage mentions --delete');
like($usage, qr/--description/, 'usage mentions --description');

# -------------------------------------------------------------------------
# main() argument validation (no virsh needed; virsh path mocked via File::Which)
# -------------------------------------------------------------------------

# No domain → dies with usage
eval { Trog::Bin::Snapshot::main() };
like($@, qr/Usage:/, 'main() with no args dies with usage');

# No operation → dies with usage
eval { Trog::Bin::Snapshot::main('example.com') };
like($@, qr/Usage:/, 'main() with domain but no operation dies with usage');

# snapshot_restore with empty snap name → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_domain_exists = sub { 1 };
    eval { Trog::Bin::Snapshot::snapshot_restore('example.com', '') };
    like($@, qr/Snapshot name required/, 'snapshot_restore dies on empty snapname');
}

# snapshot_delete with empty snap name → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_domain_exists = sub { 1 };
    eval { Trog::Bin::Snapshot::snapshot_delete('example.com', '') };
    like($@, qr/Snapshot name required/, 'snapshot_delete dies on empty snapname');
}

# snapshot_create on unknown domain → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_domain_exists = sub { 0 };
    eval { Trog::Bin::Snapshot::snapshot_create('ghost.lan') };
    like($@, qr/not found in libvirt/, 'snapshot_create dies for unknown domain');
}

# snapshot_list on unknown domain → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_domain_exists = sub { 0 };
    eval { Trog::Bin::Snapshot::snapshot_list('ghost.lan') };
    like($@, qr/not found in libvirt/, 'snapshot_list dies for unknown domain');
}

# snapshot_restore on unknown domain → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_domain_exists = sub { 0 };
    eval { Trog::Bin::Snapshot::snapshot_restore('ghost.lan', 'snap1') };
    like($@, qr/not found in libvirt/, 'snapshot_restore dies for unknown domain');
}

# snapshot_delete on unknown domain → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_domain_exists = sub { 0 };
    eval { Trog::Bin::Snapshot::snapshot_delete('ghost.lan', 'snap1') };
    like($@, qr/not found in libvirt/, 'snapshot_delete dies for unknown domain');
}

# -------------------------------------------------------------------------
# snapshot_create — captures virsh command args
# -------------------------------------------------------------------------
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_domain_exists    = sub { 1 };

    my @captured;
    local *Trog::Bin::Snapshot::_virsh_snap_create = sub { @captured = @_; return 0 };

    Trog::Bin::Snapshot::snapshot_create('myvm.lan', 'mysnap', 'test snapshot');

    is($captured[0], 'myvm.lan',        'snapshot_create passes domain to virsh');
    is($captured[2], 'mysnap',          'snapshot_create passes name to virsh');
    is($captured[4], 'test snapshot',   'snapshot_create passes description to virsh');
}

# snapshot_restore — captures virsh command args
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_domain_exists     = sub { 1 };

    my @captured;
    local *Trog::Bin::Snapshot::_virsh_snap_revert = sub { @captured = @_; return 0 };

    Trog::Bin::Snapshot::snapshot_restore('myvm.lan', 'mysnap');

    is_deeply(\@captured, ['myvm.lan', 'mysnap'], 'snapshot_restore passes correct args to virsh');
}
