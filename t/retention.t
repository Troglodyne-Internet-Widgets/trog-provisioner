#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/retention.t - scripts/retention.sh: backups older than a month go, newer ones and anything that is not a backup stay

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper::Temp();
use IPC::Run3();
use POSIX qw{strftime};

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/retention.sh";

# A logger of our own, so that the test writes nothing to the syslog of the
# machine running it.
my $bin = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$bin/logger", qq{#!/bin/sh\n[ "\$1" = --stderr ] && shift\necho "\$*" >&2\n} );
chmod( 0755, "$bin/logger" ) or die "Cannot make the fake logger executable: $!";

sub prune {
    my ( $base, $host ) = @_;

    local $ENV{PATH} = "$bin:$ENV{PATH}";
    IPC::Run3::run3( [ $script, $host, $base ], \undef, \my $out, \my $err );
    return { status => $? >> 8, err => $err // '' };
}

subtest 'a base directory with a space in it' => sub {
    my $base  = tempdir( CLEANUP => 1 ) . '/bogus backups';
    my $today = strftime( '%Y-%m-%d', localtime );
    make_path( map { "$base/bogushost/$_/etc" } '2000-01-01', $today, 'bogus-not-a-date' );

    my $r = prune( $base, 'bogushost' );
    is( $r->{status}, 0, 'it exits clean' ) or diag $r->{err};
    ok( !-e "$base/bogushost/2000-01-01",      'the backup older than a month is deleted' ) or diag $r->{err};
    ok( -d "$base/bogushost/$today",           'the backup from today is kept' );
    ok( -d "$base/bogushost/bogus-not-a-date", 'and so is what is not named for a date' );
    unlike( $r->{err}, qr/expression|No[ ]such/, 'with no complaint from the shell' ) or diag $r->{err};
};

subtest 'a host with no backups yet' => sub {
    my $base = tempdir( CLEANUP => 1 );
    make_path("$base/bogushost");

    my $r = prune( $base, 'bogushost' );
    is( $r->{status}, 0, 'it exits clean' );
    unlike( $r->{err}, qr/expression|invalid[ ]date/, 'with no complaint about a date it was never given' ) or diag $r->{err};
};

Test::NoWarnings::had_no_warnings();
done_testing();
