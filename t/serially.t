#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/serially.t - scripts/serially: a command under the lock of serial_apt

=cut

use FindBin;
use FindBin::libs;
use Test::More;
use File::Temp qw{tempdir};
use Time::HiRes();
use IPC::Run3();

my $script = "$FindBin::Bin/../scripts/serially";
my $apt    = "$FindBin::Bin/../scripts/serial_apt";
my $dir    = tempdir( CLEANUP => 1 );
local $ENV{SERIAL_APT_LOCK} = "$dir/lock";

IPC::Run3::run3( [ 'env', 'DEBIAN_FRONTEND=noninteractive', $script, 'sh', '-c', 'echo "$DEBIAN_FRONTEND $1"', 'sh', 'two words' ], \undef, \my $out, \undef );
is( $out, "noninteractive two words\n", 'it runs the command it is given, with its arguments as given, and the environment of the caller' );

# make stops a target on the status of a line, so a failure must come through.
IPC::Run3::run3( [ $script, 'sh', '-c', 'exit 3' ], \undef, \undef, \undef );
is( $? >> 8, 3, 'and it exits as the command did' );

# A debconf user waits for an apt, and an apt for a debconf user.
symlink( $apt, "$dir/sleep" ) or die "symlink sleep: $!";
my $start = Time::HiRes::time();
IPC::Run3::run3( [ 'bash', '-c', '"$0" 1 & "$1" sleep 1 & wait', "$dir/sleep", $script ], \undef, \undef, \undef );
cmp_ok( Time::HiRes::time() - $start, '>=', 1.9, 'and it waits for the lock that apt holds' );

done_testing();
