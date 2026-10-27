#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/relay_ban.t - scripts/relay_ban: what a guest behind a relay can ask of the
set of bans, and what it cannot

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Capture::Tiny    qw{capture};
use Test::MockModule qw{strict};

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/relay_ban";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $DOMAIN = 'web.test.test';
my $SET    = 'nginxrelay-bans';

# Every command answered with what $ok says.  Answers the commands that ran.
my $ok;
my @ran;
my $ban = Test::MockModule->new( 'Trog::RelayBan', no_auto => 1 );
$ban->redefine(
    run => sub {
        my (@command) = @_;
        push( @ran, "@command" );
        return $command[0] eq 'logger' ? 1 : $ok;
    }
);

# The exit status of a request, and the ipset commands that it ran.
sub ask {
    my ($request) = @_;
    @ran = ();
    my ( undef, undef, $rc ) = capture { Trog::RelayBan::main( $SET, $DOMAIN, $request ) };
    return ( $rc, [ grep { m/\Aipset/ } @ran ] );
}

subtest 'a guest bans and unbans an address' => sub {
    $ok = 1;
    my ( $rc, $ran ) = ask('ban 198.51.100.7 600');
    is( $rc, 0, 'a ban exits 0' );
    is_deeply( $ran, ['ipset -exist add nginxrelay-bans 198.51.100.7 timeout 600'], 'and adds the address for the time of the ban, or renews it' );
    like( $ran[-1], qr/\Alogger[ ].*\Q$DOMAIN\E:[ ]ban[ ]198[.]51[.]100[.]7/, 'and says in syslog which domain banned it' );

    ( $rc, $ran ) = ask('unban 198.51.100.7');
    is( $rc, 0, 'an unban exits 0' );
    is_deeply( $ran, ['ipset -exist del nginxrelay-bans 198.51.100.7'], 'and removes the address, which can be gone already' );

    ( $rc, $ran ) = ask('check 198.51.100.7');
    is_deeply( [ $rc, $ran ], [ 0, ['ipset -quiet test nginxrelay-bans 198.51.100.7'] ], 'a check of a banned address exits 0' );
    $ok = 0;
    ( $rc, $ran ) = ask('check 198.51.100.7');
    is( $rc, 1, 'and of any other address 1' );
};

subtest 'the time of a ban is what ipset can hold' => sub {
    $ok = 1;
    my %timeout = (
        '-1'         => 0,
        '0'          => 0,
        '1'          => 1,
        '2147483'    => 2147483,
        '2147484'    => 2147483,
        '9999999999' => 2147483,
    );
    foreach my $seconds ( sort { $a <=> $b } keys %timeout ) {
        my ( undef, $ran ) = ask("ban 198.51.100.7 $seconds");
        like( $ran->[0], qr/[ ]timeout[ ]\Q$timeout{$seconds}\E\z/, "a bantime of $seconds is a timeout of $timeout{$seconds}" );
    }
};

subtest 'a failure of ipset is an exit of 3' => sub {
    $ok = 0;
    is( ( ask('ban 198.51.100.7 600') )[0], 3, 'for a ban' );
    is( ( ask('unban 198.51.100.7') )[0],   3, 'and for an unban' );
    ok( !grep( { m/\Alogger/ } @ran ), 'and nothing goes to syslog as done' );
};

subtest 'it refuses anything else' => sub {
    $ok = 1;
    my %bad = (
        'nothing at all'           => undef,
        'a shell'                  => 'sh',
        'an IPv6 address'          => 'ban 2001:db8::7 600',
        'an octet over 255'        => 'ban 198.51.100.256 600',
        'a network'                => 'ban 198.51.100.0/24 600',
        'a ban with no time'       => 'ban 198.51.100.7',
        'a time that is no number' => 'ban 198.51.100.7 10m',
        'an unban with a time'     => 'unban 198.51.100.7 600',
        'a word too many'          => 'ban 198.51.100.7 600 now',
        'a command after it'       => 'ban 198.51.100.7 600;id',
    );
    foreach my $case ( sort keys %bad ) {
        my ( $rc, $ran ) = ask( $bad{$case} );
        is_deeply( [ $rc, $ran ], [ 2, [] ], "$case exits 2 and runs nothing" );
    }
    like( exception { Trog::RelayBan::main( $SET, undef, 'check 198.51.100.7' ) }, qr/names[ ]the[ ]set[ ]and[ ]the[ ]domain/, 'and a key with no domain in its command dies' );
    foreach my $set ( undef, 'nginxrelay', 'other-bans;id' ) {
        like( exception { Trog::RelayBan::main( $set, $DOMAIN, 'check 198.51.100.7' ) }, qr/names[ ]the[ ]set/, 'as does one that names no set of bans: ' . ( $set // 'none' ) );
    }
};

done_testing;
