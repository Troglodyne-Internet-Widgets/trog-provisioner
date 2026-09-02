#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use FindBin();
use FindBin::libs;

require './bin/snapshot';

# The interface is documented in POD now, and pod2usage prints that.
my $synopsis = _pod_section("$FindBin::Bin/../bin/snapshot", 'SYNOPSIS|OPTIONS');
like($synopsis, qr/--name/,   'POD documents --name');
like($synopsis, qr/--connect/,'POD documents --connect');
like($synopsis, qr/DOMAIN/,   'POD documents the DOMAIN argument');

# No domain -> usage, non-zero exit.  This one has to be a real run, since
# pod2usage exits rather than dying.
my ($out, $rc) = _run("$FindBin::Bin/../bin/snapshot");
isnt($rc, 0, 'no arguments exits non-zero');
like($out, qr/No domain passed/, 'saying what was missing');
like($out, qr/Usage:/,           'and printing the usage out of the POD');

# libvirt refuses to snapshot -> dies
{
    no warnings 'redefine';
    local *Trog::HV::create_snapshot        = sub { 0 };
    local *Trog::HV::snapshot_current_name  = sub { undef };

    eval { Trog::Bin::Snapshot::main('myvm.lan') };
    like($@, qr/Failed to create snapshot/, 'main() dies when the snapshot fails');
}

# No current snapshot after create -> dies
{
    no warnings 'redefine';
    local *Trog::HV::create_snapshot       = sub { 1 };
    local *Trog::HV::snapshot_current_name = sub { undef };

    eval { Trog::Bin::Snapshot::main('myvm.lan') };
    like($@, qr/No current snapshot/, 'main() dies when no snapshot is current after create');
}

# Current snapshot unchanged -> dies
{
    no warnings 'redefine';
    local *Trog::HV::create_snapshot       = sub { 1 };
    local *Trog::HV::snapshot_current_name = sub { 'same-snap' };

    eval { Trog::Bin::Snapshot::main('myvm.lan') };
    like($@, qr/unchanged after create/, 'main() dies when the current snapshot does not change');
}

# Happy path -- nothing was current before
{
    no warnings 'redefine';
    my $call = 0;
    local *Trog::HV::create_snapshot       = sub { 1 };
    local *Trog::HV::snapshot_current_name = sub { ++$call == 1 ? undef : 'new-snap' };

    my $rc;
    eval { $rc = Trog::Bin::Snapshot::main('myvm.lan') };
    is($@,  '', 'no exception on success when nothing was current before');
    is($rc, 0,  'main() returns 0 on success');
}

# Happy path -- before differs from after
{
    no warnings 'redefine';
    my $call = 0;
    local *Trog::HV::create_snapshot       = sub { 1 };
    local *Trog::HV::snapshot_current_name = sub { ++$call == 1 ? 'old-snap' : 'new-snap' };

    my $rc;
    eval { $rc = Trog::Bin::Snapshot::main('myvm.lan') };
    is($@,  '', 'no exception when before differs from after');
    is($rc, 0,  'main() returns 0');
}

# --name reaches libvirt
{
    no warnings 'redefine';
    my @captured;
    my $call = 0;
    local *Trog::HV::create_snapshot       = sub { @captured = @_; return 1 };
    local *Trog::HV::snapshot_current_name = sub { ++$call == 1 ? undef : 'mysnap' };

    Trog::Bin::Snapshot::main(qw{myvm.lan --name mysnap});
    is($captured[1], 'myvm.lan', 'domain forwarded');
    is($captured[2], 'mysnap',   '--name value forwarded');
}

sub _run {
    my (@cmd) = @_;
    my $out = qx{$^X @cmd 2>&1};
    return ($out, $?);
}

sub _pod_section {
    my ($file, $sections) = @_;
    require Pod::Usage;
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
