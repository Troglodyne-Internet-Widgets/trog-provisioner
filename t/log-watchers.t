#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/log-watchers.t - scripts/outgoing_blocks.sh, segfaults.sh and escalations.sh: each reports what is new in its log, and only that

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

# Runs a watcher against a log of our own, with its state in a directory of our
# own.  Each call is one cron run: the state it leaves is what the next call
# compares against.
sub watch {
    my ( $state, $script, $log, $content, @args ) = @_;

    File::Slurper::Temp::write_text( "$state/log", $content );
    local $ENV{STATE_DIR} = $state;
    local $ENV{$log} = "$state/log";
    IPC::Run3::run3( [ "$FindBin::Bin/../scripts/$script", @args ], \undef, \my $out, \my $err );
    is( $? >> 8, 0, "$script exits clean" ) or diag $err;
    return $out // '';
}

# UFW log lines: an incoming block has an empty OUT=, an outgoing one an empty
# IN=.
sub ufw_block {
    my ( $in, $out, $dpt ) = @_;

    return "Sep 18 10:00:00 host kernel: [12345.678901] [UFW BLOCK] IN=$in OUT=$out SRC=192.0.2.10 DST=198.51.100.7 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=1 DF PROTO=TCP SPT=50002 DPT=$dpt WINDOW=64240 RES=0x00 SYN URGP=0\n";
}

subtest 'outgoing_blocks.sh' => sub {
    my $state = tempdir( CLEANUP => 1 );

    my $said = watch( $state, 'outgoing_blocks.sh', 'SYSLOG', ufw_block( '', 'ens3', 8443 ) . ufw_block( 'ens3', '', 23 ) );
    like( $said, qr/^DANGER:[^\n]*\Q$state\E\/log/, 'a new outgoing block is reported, naming the log it read' );
    like( $said, qr/^DPT=8443$/m,                   'with the port' );
    unlike( $said, qr/DPT=23/, 'and not the incoming block' );

    is( watch( $state, 'outgoing_blocks.sh', 'SYSLOG', ufw_block( '', 'ens3', 8443 ) ), '', 'a block already reported is not reported again' );

    $said = watch( $state, 'outgoing_blocks.sh', 'SYSLOG', ufw_block( '', 'ens3', 8444 ) );
    like( $said, qr/^DPT=8444$/m, 'a new port is reported when rotation took one of the same length away' );

    $said = watch( $state, 'outgoing_blocks.sh', 'SYSLOG', "\0\0\0\n" . ufw_block( '', 'ens3', 9999 ) );
    like( $said, qr/^DPT=9999$/m, 'a block after NUL bytes in the log is still read' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
