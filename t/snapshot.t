#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/snapshot.t - bin/snapshot: taking one, and naming it

=cut

use Test::More;
use Test::Fatal qw{exception};
use IPC::Run3();
use Capture::Tiny    qw{capture_stdout};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use Pod::Usage();

use FindBin;
use FindBin::libs;

# Loaded so Test::MockModule has a package to attach to: Trog::HV requires its
# backend lazily, and it is named only as a string below.
use Trog::HV::Libvirt();    ## no critic (ProhibitUnusedImports)

# The backend loads its client when it opens a connection, and these subtests
# hand it a connection it did not open.  So the flag constants below come from
# here rather than from Trog::HV::Libvirt.
use Sys::Virt();    ## no critic (ProhibitUnusedImports)

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

require_ok("$FindBin::Bin/../bin/snapshot")
  or BAIL_OUT('bin/snapshot does not load; the install is incomplete');

# Point --hvconf at nothing, so these never read the fleet file of whatever
# machine the suite happens to be running on.
my $NO_FLEET = tempdir( CLEANUP => 1 ) . '/hypervisors.conf';
sub main_snapshot (@args) { return Trog::Bin::Snapshot::main( '--hvconf', $NO_FLEET, @args ) }

# The interface is documented in POD now, and pod2usage prints that.
my $synopsis = _pod_section( "$FindBin::Bin/../bin/snapshot", 'SYNOPSIS|OPTIONS' );
like( $synopsis, qr/--name/,       'POD documents --name' );
like( $synopsis, qr/--hypervisor/, 'POD documents --hypervisor' );
like( $synopsis, qr/--disk-only/,  'POD documents --disk-only' );
like( $synopsis, qr/DOMAIN/,       'POD documents the DOMAIN argument' );

# No domain -> usage, non-zero exit.  This one has to be a real run, since
# pod2usage exits rather than dying.
my ( $out, $rc ) = _run("$FindBin::Bin/../bin/snapshot");
isnt( $rc, 0, 'no arguments exits non-zero' );
like( $out, qr/No[ ]domain[ ]passed/, 'saying what was missing' );
like( $out, qr/Usage:/,               'and printing the usage out of the POD' );

# libvirt refuses to snapshot -> dies
{
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( create_snapshot       => sub { 0 } );
    $hv_mock->redefine( snapshot_current_name => sub { undef } );

    like( exception { main_snapshot('myvm.lan') }, qr/Failed[ ]to[ ]create[ ]snapshot/, 'main() dies when the snapshot fails' );
}

# No current snapshot after create -> dies
{
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( create_snapshot       => sub { 1 } );
    $hv_mock->redefine( snapshot_current_name => sub { undef } );

    like( exception { main_snapshot('myvm.lan') }, qr/No[ ]current[ ]snapshot/, 'main() dies when no snapshot is current after create' );
}

# Current snapshot unchanged -> dies
{
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( create_snapshot       => sub { 1 } );
    $hv_mock->redefine( snapshot_current_name => sub { 'same-snap' } );

    like( exception { main_snapshot('myvm.lan') }, qr/unchanged[ ]after[ ]create/, 'main() dies when the current snapshot does not change' );
}

# Happy path -- nothing was current before
{
    my $call    = 0;
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( create_snapshot       => sub { 1 } );
    $hv_mock->redefine( snapshot_current_name => sub { ++$call == 1 ? undef : 'new-snap' } );

    my $status;
    is( exception { $status = main_snapshot('myvm.lan') }, undef, 'no exception on success when nothing was current before' );
    is( $status,                                           0,     'main() returns 0 on success' );
}

# Happy path -- before differs from after
{
    my $call    = 0;
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( create_snapshot       => sub { 1 } );
    $hv_mock->redefine( snapshot_current_name => sub { ++$call == 1 ? 'old-snap' : 'new-snap' } );

    my $status;
    is( exception { $status = main_snapshot('myvm.lan') }, undef, 'no exception when before differs from after' );
    is( $status,                                           0,     'main() returns 0' );
}

# --name reaches libvirt
{
    my @captured;
    my $call    = 0;
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( create_snapshot       => sub { @captured = @_; return 1 } );
    $hv_mock->redefine( snapshot_current_name => sub { ++$call == 1 ? undef : 'mysnap' } );

    main_snapshot(qw{myvm.lan --name mysnap});
    is( $captured[1], 'myvm.lan', 'domain forwarded' );
    is( $captured[2], 'mysnap',   '--name value forwarded' );
}

# Everything above redefines create_snapshot, which is how bin/snapshot came to
# advertise a snapshot libvirt would refuse to take: the mock answered a
# question that could never have been asked of a real hypervisor.  These two go
# through the real one, and only stand libvirt itself out of the way.
{

    package FakeSnapDomain;

    sub new       { my ( $class, $seen ) = @_; return bless { active => 1, seen => $seen }, $class }
    sub is_active { my ($self) = @_; return $self->{active} }
    sub destroy   { my ($self) = @_; $self->{active} = 0; push @{ $self->{seen} }, 'destroy'; return 1 }
    sub create    { my ($self) = @_; $self->{active} = 1; push @{ $self->{seen} }, 'create';  return 1 }

    sub create_snapshot {
        my ( $self, $xml, $flags ) = @_;
        push @{ $self->{seen} }, $xml;
        return 1;
    }
}

{
    my @seen;
    my $dom     = FakeSnapDomain->new( \@seen );
    my $call    = 0;
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( _domain               => sub { $dom } );
    $hv_mock->redefine( snapshot_current_name => sub { ++$call == 1 ? undef : 'live-snap' } );

    is( exception { main_snapshot('myvm.lan') }, undef, 'a default run snapshots a guest that is up' );
    like( $seen[0], qr/<memory/, 'asking libvirt for the full system snapshot it will actually give for a running domain' );
    ok( !( grep { $_ eq 'destroy' } @seen ), 'without stopping it' );
}

{
    my @seen;
    my $dom     = FakeSnapDomain->new( \@seen );
    my $call    = 0;
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( _domain               => sub { $dom } );
    $hv_mock->redefine( snapshot_current_name => sub { ++$call == 1 ? undef : 'disk-snap' } );

    my $said = capture_stdout { main_snapshot(qw{myvm.lan --disk-only}) };

    is( $seen[0], 'destroy', '--disk-only stops the guest first' );
    unlike( $seen[1], qr/<memory/, 'and asks for the disk alone' );
    is( $seen[2], 'create', 'then starts it again, an operator having asked for a snapshot rather than a shutdown' );
    like( $said, qr/Stopping[ ]myvm[.]lan[ ]for[ ]this/,  'saying beforehand that the guest is going down' );
    like( $said, qr/back[ ]the[ ]way[ ]it[ ]was[ ]found/, 'and afterwards that it is back' );
}

sub _run {
    my (@cmd) = @_;
    my $said = q{};
    IPC::Run3::run3( [ $^X, @cmd ], \undef, \$said, \$said );
    return ( $said, $? );
}

sub _pod_section {
    my ( $file, $sections ) = @_;
    open( my $fh, '>', \my $text ) or die $!;
    Pod::Usage::pod2usage(
        -input    => $file,
        -output   => $fh,
        -exitval  => 'NOEXIT',
        -verbose  => 99,
        -sections => $sections,
    );
    close($fh) or die "Could not close the POD read out of $file: $!";
    return $text // '';
}

done_testing;
