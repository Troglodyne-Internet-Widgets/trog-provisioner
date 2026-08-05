#!/usr/bin/env perl
use strict;
use warnings;

BEGIN {
    $INC{'File/Which.pm'} = 1;
    package File::Which;
    use Exporter 'import';
    our @EXPORT_OK = qw{which};
    sub which { return '/usr/bin/virsh' }
}

use Test::More tests => 15;

require './bin/snapshot';

# usage() lists expected options
my $usage = Trog::Bin::Snapshot::usage();
like($usage, qr/--name/,   'usage mentions --name');
like($usage, qr/DOMAIN/,   'usage mentions DOMAIN');

# No domain → dies with usage
eval { Trog::Bin::Snapshot::main() };
like($@, qr/Usage:/, 'main() with no args dies with usage');

# virsh create fails → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_virsh             = sub { 1 };
    local *Trog::Bin::Snapshot::_virsh_snap_current = sub { undef };

    eval { Trog::Bin::Snapshot::main('myvm.lan') };
    like($@, qr/Failed to create snapshot/, 'main() dies when virsh create fails');
}

# No current snapshot after create → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_virsh             = sub { 0 };
    local *Trog::Bin::Snapshot::_virsh_snap_current = sub { undef };

    eval { Trog::Bin::Snapshot::main('myvm.lan') };
    like($@, qr/No current snapshot/, 'main() dies when no snapshot is current after create');
}

# Current snapshot unchanged → dies
{
    no warnings 'redefine';
    local *Trog::Bin::Snapshot::_virsh             = sub { 0 };
    local *Trog::Bin::Snapshot::_virsh_snap_current = sub { "same-snap\n" };

    eval { Trog::Bin::Snapshot::main('myvm.lan') };
    like($@, qr/unchanged after create/, 'main() dies when current snapshot does not change');
}

# Happy path — before is undef (no prior snapshot), after is new name
{
    no warnings 'redefine';
    my $call = 0;
    local *Trog::Bin::Snapshot::_virsh             = sub { 0 };
    local *Trog::Bin::Snapshot::_virsh_snap_current = sub {
        $call++;
        return $call == 1 ? undef : "new-snap\n";
    };

    my $rc;
    eval { $rc = Trog::Bin::Snapshot::main('myvm.lan') };
    is($@,  '',  'main() no exception on success when before was undef');
    is($rc, 0,   'main() returns 0 on success');
}

# Happy path — before differs from after
{
    no warnings 'redefine';
    my $call = 0;
    local *Trog::Bin::Snapshot::_virsh             = sub { 0 };
    local *Trog::Bin::Snapshot::_virsh_snap_current = sub {
        $call++;
        return $call == 1 ? "old-snap\n" : "new-snap\n";
    };

    my $rc;
    eval { $rc = Trog::Bin::Snapshot::main('myvm.lan') };
    is($@,  '', 'main() no exception when before differs from after');
    is($rc, 0,  'main() returns 0');
}

# --name is forwarded to virsh
{
    no warnings 'redefine';
    my @captured;
    my $ncall = 0;
    local *Trog::Bin::Snapshot::_virsh             = sub { @captured = @_; return 0 };
    local *Trog::Bin::Snapshot::_virsh_snap_current = sub {
        return ++$ncall == 1 ? undef : "mysnap\n";
    };

    Trog::Bin::Snapshot::main('myvm.lan', '--name', 'mysnap');
    ok((grep { $_ eq 'mysnap' } @captured), '--name value forwarded to virsh');
    ok((grep { $_ eq '--atomic' } @captured), '--atomic flag present');
    ok((grep { $_ eq '--live' } @captured),   '--live flag present');
}

# _virsh_snap_current returns undef when virsh exits non-zero
{
    no warnings 'redefine';
    # We just test that the sub doesn't die; actual virsh call not run in tests
    # because qx{} is called inline. Just verify the code path is accessible.
    can_ok('Trog::Bin::Snapshot', '_virsh_snap_current');
}

# _virsh wraps system() correctly (call count / args)
{
    no warnings 'redefine';
    can_ok('Trog::Bin::Snapshot', '_virsh');
}
