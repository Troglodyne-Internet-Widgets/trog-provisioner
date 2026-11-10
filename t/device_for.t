#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/device_for.t - scripts/device_for: a key of F</root/devices.map> finds its
own line, and only its own

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/device_for";

my $dir = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$dir/devices.map", <<'MAP' );
/bogus/data2=vdc
/bogus/d=ta=vdd
/bogus/data=vdb
/bogus/disk=/dev/vde
MAP

# Returns what it exits with, prints, and says on stderr.
sub device_for {
    my ( $key, $map ) = @_;
    local $ENV{DEVICES_MAP} = $map // "$dir/devices.map";
    IPC::Run3::run3( [ $script, $key ], \undef, \my $out, \my $err );
    return ( $? >> 8, $out, $err );
}

subtest 'a key finds the line that is all of it' => sub {
    is( ( device_for('/bogus/data') )[1],  "vdb\n",      'a key that another key begins with finds its own line, and not the first line it begins' );
    is( ( device_for('/bogus/data2') )[1], "vdc\n",      'and the longer key finds its own' );
    is( ( device_for('/bogus/disk') )[1],  "/dev/vde\n", 'a disk is a path to its device' );
    is( ( device_for('/bogus/d=ta') )[1],  "vdd\n",      'a key may hold an =, because the device is what is after the last one' );
};

subtest 'a key with no line of its own is refused' => sub {
    foreach my $key (qw{/bogus/dat /bogus/d.ta /bogus}) {
        my ( $rc, $out, $err ) = device_for($key);
        is( $rc,  1,   "$key, which only part of a line matches, exits 1" );
        is( $out, q{}, 'and prints no device' );
        like( $err, qr/no\ device\ for\ '\Q$key\E'/, 'and says which key it could not find' );
    }
};

subtest 'without a map' => sub {
    my ( $rc, undef, $err ) = device_for( '/bogus/data', "$dir/bogus-missing.map" );
    is( $rc, 1, 'it exits 1' );
    like( $err, qr/no\ \S+bogus-missing[.]map/, 'and names the map it did not find' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
