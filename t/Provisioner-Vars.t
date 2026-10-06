#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Vars.t - the shared numbers mean what their names say

=cut

use Test::More;
use IPC::Run3();
use Time::Piece();

use FindBin::libs;

use Provisioner::Vars();

subtest 'each byte unit is 1024 of the one below it' => sub {
    is( $Provisioner::Vars::MB, $Provisioner::Vars::KB * $Provisioner::Vars::KB, 'a megabyte is 1024 kilobytes' );
    is( $Provisioner::Vars::GB, $Provisioner::Vars::MB * $Provisioner::Vars::KB, 'a gigabyte is 1024 megabytes' );
    is( $Provisioner::Vars::TB, $Provisioner::Vars::GB * $Provisioner::Vars::KB, 'a terabyte is 1024 gigabytes' );
};

# Each status is what $? really holds after a child that did that, which is
# what a test that fakes one stands in for.
subtest 'each wait status is what $? holds after a child that did it' => sub {
    my $status_of = sub ($script) {
        IPC::Run3::run3( [ 'sh', '-c', $script ], \undef, \my $out, \my $err );
        return $?;
    };

    is( $status_of->('exit 1'),                                 $Provisioner::Vars::STATUS_EXIT_1,    'exit 1' );
    is( $status_of->('exit 2'),                                 $Provisioner::Vars::STATUS_EXIT_2,    'exit 2' );
    is( $status_of->('bogus-command-that-is-not-there-at-all'), $Provisioner::Vars::STATUS_NOT_FOUND, 'a command the shell cannot find' );
};

subtest 'a month of hours is a year of them over twelve' => sub {
    is( $Provisioner::Vars::HOURS_A_MONTH * 12, 8760, '730 hours, twelve times, is 365 days' );
};

subtest 'a day of seconds is what a timestamp moves in a day' => sub {
    is( $Provisioner::Vars::SECONDS_A_DAY, Time::Piece->strptime( '2026-01-02', '%Y-%m-%d' )->epoch - Time::Piece->strptime( '2026-01-01', '%Y-%m-%d' )->epoch, 'the seconds between two midnights' );
};

done_testing();
