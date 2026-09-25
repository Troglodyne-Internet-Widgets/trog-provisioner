#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/post-install.t - scripts/post_install: every deferred task runs, whatever the one before it did

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use File::Slurper();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/post_install";

## no critic (ValuesAndExpressions::ProhibitFiletest_rwxRWX)
ok( -x $script, 'post_install is there and executable' );

# Run it over a queue of our own.  Each task appends its own name to a file, so
# what ran is a list rather than a guess about output.
sub run_queue {
    my (@tasks) = @_;

    my $dir  = tempdir( CLEANUP => 1 );
    my $ran  = "$dir/ran";
    my @body = map { my $t = $_; $t =~ s/%RAN%/$ran/g; $t } @tasks;

    File::Slurper::Temp::write_text( "$dir/queue", join( "\n", @body ) . "\n" );

    local $ENV{POST_INSTALL_QUEUE} = "$dir/queue";
    IPC::Run3::run3( [$script], \undef, \my $out, \my $err );

    my $done = eval { File::Slurper::read_text($ran) } // '';
    return { status => $? >> 8, out => $out // '', err => $err // '', ran => [ split( m/\n/, $done ) ] };
}

subtest 'every task runs, and the exit code is the answer at the end' => sub {
    my $r = run_queue( 'echo one >> %RAN%', 'echo two >> %RAN%' );
    is_deeply( $r->{ran}, [qw{one two}], 'both ran' );
    is( $r->{status}, 0, 'and it exits clean' );

    $r = run_queue( 'echo one >> %RAN%', 'false', 'echo three >> %RAN%' );
    is_deeply( $r->{ran}, [qw{one three}], 'a failing task does not stop the ones after it' );
    is( $r->{status}, 1, 'and the failure is still the exit code' );
    ok( index( $r->{err}, 'postrun FAILED: false' ) >= 0, 'saying which task it was' ) or diag $r->{err};
};

# The loop is fed the task list on stdin, and bash -c inherits it.  A task that
# read stdin therefore ate the rest of the queue and the loop ended at end of
# input -- no error, no failed task, just deferred work that stopped happening.
# On a tcms guest that was cpanm, and it took the service build and the ufw
# reload with it.
subtest 'a task that reads stdin does not eat the queue' => sub {
    my $r = run_queue( 'echo one >> %RAN%', 'cat > /dev/null', 'echo three >> %RAN%', 'echo four >> %RAN%' );

    is_deeply( $r->{ran}, [qw{one three four}], 'everything after the reader still ran' )
      or diag "out: $r->{out}\nerr: $r->{err}";
};

# The queue is appended to and was never emptied, so a second makefile run on a
# guest replayed every earlier run's deferred work.  Moving it aside is what
# ends that, and it has to happen after the loop: the loop reads the file it is
# renaming.
# Under make -j, targets finish in any order, so queue_postrun_task tags each
# task with the slot of its target, and post_install runs them by slot.
subtest 'the queue runs by slot, and in queued order within one' => sub {
    my $r = run_queue( "30\techo c >> %RAN%", "10\techo a >> %RAN%", "30\techo d >> %RAN%", 'echo e >> %RAN%', "20\techo b >> %RAN%" );
    is_deeply( $r->{ran}, [qw{a b c d e}], 'by slot, ties in the order queued, and a task with no slot last' );
};

subtest 'queue_postrun_task tags a task with the slot of its target' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{POST_INSTALL_QUEUE} = "$dir/queue";
    my $queue = "$FindBin::Bin/../scripts/queue_postrun_task";

    {
        local $ENV{POSTRUN_SLOT} = 7;
        IPC::Run3::run3( [ $queue, qw{systemctl restart nginx} ], \undef, \undef, \undef );
        is( $? >> 8, 0, 'queue_postrun_task ran clean' );
    }
    delete local $ENV{POSTRUN_SLOT};
    IPC::Run3::run3( [ $queue, 'echo by hand' ], \undef, \undef, \undef );

    # Many writers at once, as make -j gives.  Each line must come out whole.
    my $writers = 'for n in $(seq 1 20); do POSTRUN_SLOT=$((100 + n)) "$0" "echo writer $n $1" & done; wait';
    IPC::Run3::run3( [ 'bash', '-c', $writers, $queue, 'x' x 200 ], \undef, \undef, \undef );

    my @lines = split m/\n/, File::Slurper::read_text("$dir/queue");
    is( $lines[0],                                                             "7\tsystemctl restart nginx", 'the task after the slot the makefile exported, one line, words kept together' );
    is( $lines[1],                                                             "999999\techo by hand",       'and a task queued outside the makefile after every slot' );
    is( scalar( grep { m/\A1\d{2}\techo[ ]writer[ ]\d+[ ]x{200}\z/ } @lines ), 20,                           'twenty writers at once leave twenty whole lines' );
};

subtest 'the queue is moved aside once it has run' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $ran = "$dir/ran";
    File::Slurper::Temp::write_text( "$dir/queue", "echo one >> $ran\necho two >> $ran\n" );

    local $ENV{POST_INSTALL_QUEUE} = "$dir/queue";
    IPC::Run3::run3( [$script], \undef, \my $out, \my $err );
    is( $? >> 8, 0, 'it ran clean' ) or diag $err;

    ok( !-e "$dir/queue", 'the queue is gone from where the next run would look' );

    my ($aside) = glob "$dir/queue.ran_at_*";
    ok( $aside, 'and is beside it under a name saying when it ran' );
    is( File::Slurper::read_text($aside), "echo one >> $ran\necho two >> $ran\n", 'holding what it ran' ) if $aside;

    # Which is the whole point: the tasks do not happen twice.
    IPC::Run3::run3( [$script], \undef, \my $again_out, \my $again_err );
    is( $? >> 8,                        0,            'a second run over the same path is clean' );
    is( File::Slurper::read_text($ran), "one\ntwo\n", 'and ran nothing again' );
};

subtest 'a queue whose task failed is moved aside too' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $ran = "$dir/ran";
    File::Slurper::Temp::write_text( "$dir/queue", "echo one >> $ran\nfalse\n" );

    local $ENV{POST_INSTALL_QUEUE} = "$dir/queue";
    IPC::Run3::run3( [$script], \undef, \my $out, \my $err );
    is( $? >> 8, 1, 'the failure is still the exit code' );

    # Left where it was, the next run would replay the lot -- which is the bug,
    # not a retry.  The failed line is still in the copy, and .postrun_failed in
    # the makefile is what carries the failure forward.
    ok( !-e "$dir/queue", 'the queue is still moved aside' );
    my ($aside) = glob "$dir/queue.ran_at_*";
    ok( $aside,                                                            'under the same kind of name' );
    ok( $aside && index( File::Slurper::read_text($aside), 'false' ) >= 0, 'with the task that failed still in it' );
};

subtest 'an empty queue is nothing to do' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/queue", q{} );

    local $ENV{POST_INSTALL_QUEUE} = "$dir/queue";
    IPC::Run3::run3( [$script], \undef, \my $out, \my $err );
    is( $? >> 8, 0, 'it exits clean rather than complaining' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
