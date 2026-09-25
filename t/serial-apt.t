#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/serial-apt.t - scripts/serial_apt: the command it is linked as, one at a time

=cut

use FindBin;
use FindBin::libs;
use Test::More;
use File::Temp qw{tempdir};
use Time::HiRes();
use IPC::Run3();

my $script = "$FindBin::Bin/../scripts/serial_apt";
my $dir    = tempdir( CLEANUP => 1 );

# Linked as a harmless command in place of apt, which the script runs from
# /usr/bin by the name of the link.
symlink( $script, "$dir/$_" ) or die "symlink $_: $!" for qw{echo sleep};
local $ENV{SERIAL_APT_LOCK} = "$dir/lock";

IPC::Run3::run3( [ "$dir/echo", 'two words', 'three' ], \undef, \my $out, \my $err );
is( $out, "two words three\n", 'it runs the command it is linked as, with the arguments as given' );

# Two at once take as long as both, because the second waits for the lock.
my $start = Time::HiRes::time();
IPC::Run3::run3( [ 'bash', '-c', '"$0" 1 & "$0" 1 & wait', "$dir/sleep" ], \undef, \undef, \undef );
cmp_ok( Time::HiRes::time() - $start, '>=', 1.9, 'and two at once run one after the other' );

done_testing();
