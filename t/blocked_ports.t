#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/blocked_ports.t - scripts/blocked_incoming_ports.sh and blocked_outgoing_ports.sh: each lists the connections blocked in its own direction, as ufw_connection_attempts selects them

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

# Lines as UFW writes them.  An incoming block has an empty OUT=, an outgoing
# one an empty IN=, and a forwarded one names both interfaces.  The ACK FIN in
# each direction is the late end of a connection that conntrack forgot, and a
# SYN ACK is the answer to one.  Neither tries to open a connection.
my $LOG = <<'LOG';
Sep 18 10:00:00 host kernel: [12345.678901] [UFW BLOCK] IN=ens3 OUT= MAC=52:54:00:aa:bb:cc:52:54:00:dd:ee:ff:08:00 SRC=203.0.113.5 DST=192.0.2.10 LEN=44 TOS=0x00 PREC=0x00 TTL=242 ID=54321 PROTO=TCP SPT=40001 DPT=23 WINDOW=1024 RES=0x00 SYN URGP=0
Sep 18 10:00:01 host kernel: [12346.678901] [UFW BLOCK] IN= OUT=ens3 SRC=192.0.2.10 DST=198.51.100.7 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=1 DF PROTO=TCP SPT=50002 DPT=8443 WINDOW=64240 RES=0x00 SYN URGP=0
Sep 18 10:00:02 host kernel: [12347.678901] [UFW BLOCK] IN=tun0 OUT=ens3 MAC= SRC=10.8.0.2 DST=198.51.100.9 LEN=60 TOS=0x00 PREC=0x00 TTL=63 ID=2 DF PROTO=TCP SPT=51003 DPT=25 WINDOW=64240 RES=0x00 SYN URGP=0
Sep 18 10:00:04 host kernel: [12348.678901] [UFW BLOCK] IN=ens3 OUT= MAC=52:54:00:aa:bb:cc:52:54:00:dd:ee:ff:08:00 SRC=203.0.113.5 DST=192.0.2.10 LEN=52 TOS=0x00 PREC=0x00 TTL=50 ID=3 DF PROTO=TCP SPT=443 DPT=40005 WINDOW=501 RES=0x00 ACK FIN URGP=0
Sep 18 10:00:05 host kernel: [12349.678901] [UFW BLOCK] IN= OUT=ens3 SRC=192.0.2.10 DST=198.51.100.7 LEN=52 TOS=0x00 PREC=0x00 TTL=64 ID=4 DF PROTO=TCP SPT=25 DPT=40006 WINDOW=510 RES=0x00 ACK PSH FIN URGP=0
Sep 18 10:00:06 host kernel: [12350.678901] [UFW BLOCK] IN= OUT=ens3 SRC=192.0.2.10 DST=198.51.100.7 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=5 DF PROTO=TCP SPT=993 DPT=40007 WINDOW=65160 RES=0x00 ACK SYN URGP=0
Sep 18 10:00:07 host kernel: [12351.678901] [UFW BLOCK] IN= OUT=ens3 SRC=192.0.2.10 DST=198.51.100.7 LEN=100 TOS=0x00 PREC=0x00 TTL=64 ID=6 DF PROTO=UDP SPT=40008 DPT=1194 LEN=80
Sep 18 10:00:08 host kernel: [12352.678901] [UFW BLOCK] IN=ens3 OUT= MAC=52:54:00:aa:bb:cc:52:54:00:dd:ee:ff:08:00 SRC=203.0.113.5 DST=192.0.2.10 LEN=44 TOS=0x00 PREC=0x00 TTL=242 ID=7 PROTO=TCP SPT=40009 DPT=23 WINDOW=1024 RES=0x00 SYN URGP=0
Sep 18 10:00:09 host sshd[999]: Accepted publickey for bogus from 203.0.113.5 port 40004 ssh2
LOG

my $dir = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$dir/syslog", $LOG );

sub ports {
    my ($script) = @_;

    IPC::Run3::run3( [ "$FindBin::Bin/../scripts/$script", "$dir/syslog" ], \undef, \my $out, \my $err );
    is( $? >> 8, 0, "$script exits clean" ) or diag $err;
    return [ split( m/\n/, $out // '' ) ];
}

is_deeply( ports('blocked_incoming_ports.sh'), ['PROTO=TCP DPT=23'],                           'incoming lists each port that a connection tried to reach once, and no reply' );
is_deeply( ports('blocked_outgoing_ports.sh'), [ 'PROTO=TCP DPT=8443', 'PROTO=UDP DPT=1194' ], 'outgoing lists the connections that went out, UDP too, and no reply' );

Test::NoWarnings::had_no_warnings();
done_testing();
