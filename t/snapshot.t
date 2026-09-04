#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';
use Test::More;
use Test::MockModule qw{strict};
use File::Temp qw{tempdir};
use Pod::Usage();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }

require_ok("$FindBin::Bin/../bin/snapshot")
  or BAIL_OUT('bin/snapshot does not load; the install is incomplete');

# Point --hvconf at nothing, so these never read the fleet file of whatever
# machine the suite happens to be running on.
my $NO_FLEET = tempdir(CLEANUP => 1) . '/hypervisors.conf';
sub main_snapshot { return Trog::Bin::Snapshot::main('--hvconf', $NO_FLEET, @_) }

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
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(create_snapshot        => sub { 0 });
    $hv_mock->redefine(snapshot_current_name  => sub { undef });

    eval { main_snapshot('myvm.lan') };
    like($@, qr/Failed to create snapshot/, 'main() dies when the snapshot fails');
}

# No current snapshot after create -> dies
{
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(create_snapshot       => sub { 1 });
    $hv_mock->redefine(snapshot_current_name => sub { undef });

    eval { main_snapshot('myvm.lan') };
    like($@, qr/No current snapshot/, 'main() dies when no snapshot is current after create');
}

# Current snapshot unchanged -> dies
{
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(create_snapshot       => sub { 1 });
    $hv_mock->redefine(snapshot_current_name => sub { 'same-snap' });

    eval { main_snapshot('myvm.lan') };
    like($@, qr/unchanged after create/, 'main() dies when the current snapshot does not change');
}

# Happy path -- nothing was current before
{
    my $call = 0;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(create_snapshot       => sub { 1 });
    $hv_mock->redefine(snapshot_current_name => sub { ++$call == 1 ? undef : 'new-snap' });

    my $rc;
    eval { $rc = main_snapshot('myvm.lan') };
    is($@,  '', 'no exception on success when nothing was current before');
    is($rc, 0,  'main() returns 0 on success');
}

# Happy path -- before differs from after
{
    my $call = 0;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(create_snapshot       => sub { 1 });
    $hv_mock->redefine(snapshot_current_name => sub { ++$call == 1 ? 'old-snap' : 'new-snap' });

    my $rc;
    eval { $rc = main_snapshot('myvm.lan') };
    is($@,  '', 'no exception when before differs from after');
    is($rc, 0,  'main() returns 0');
}

# --name reaches libvirt
{
    my @captured;
    my $call = 0;
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(create_snapshot       => sub { @captured = @_; return 1 });
    $hv_mock->redefine(snapshot_current_name => sub { ++$call == 1 ? undef : 'mysnap' });

    main_snapshot(qw{myvm.lan --name mysnap});
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
