#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/relay_files.t - scripts/relay_files: the lock that the relay clients share

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp();
use Fcntl();
use POSIX();
use Time::HiRes();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/relay_files";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# The lock of $dir, held as another client holds it, until it is closed.
sub held_lock {
    my ($dir) = @_;
    open( my $held, '>>', "$dir/.lock" ) or die "Cannot open the lock: $!";
    flock( $held, Fcntl::LOCK_EX() )     or die "Cannot take the lock: $!";
    return $held;
}

subtest 'a registration waits for another one, but not forever' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    local $Trog::RelayFiles::LOCK_WAIT = 0.5;

    my $held  = held_lock($dir);
    my $start = Time::HiRes::time();
    my $err   = exception { Trog::RelayFiles::lock_dir( $dir, 'some_client' ) };
    my $took  = Time::HiRes::time() - $start;
    like( $err, qr/held[ ]\S+\/[.]lock[ ]for[ ]all[ ]of[ ]the[ ]0[.]5[ ]seconds/, 'a lock that another one holds for too long is an error that names the file' );
    like( $err, qr/-C[ ]some_client[ ]shows/,                                     'and the client to look for' );
    cmp_ok( $took, '>=', 0.5, 'after the whole of the wait' );

    # A child that lets go partway through the wait.
    local $Trog::RelayFiles::LOCK_WAIT = 5;
    my $pid = fork() // die "Cannot fork: $!";
    if ( !$pid ) {
        Time::HiRes::sleep(0.5);
        POSIX::_exit( close($held) ? 0 : 1 );
    }
    close $held or die "Cannot close the lock: $!";
    ok( Trog::RelayFiles::lock_dir( $dir, 'some_client' ), 'and the lock that the other one gives back is taken' );
    waitpid( $pid, 0 );
};

done_testing;
