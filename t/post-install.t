#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/post-install.t - scripts/post_install: the queue of deferred work, in the
order of the targets, each task once, whatever the one before it did

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();
use IPC::Run3();
use DBI();
use Cpanel::JSON::XS qw{decode_json};

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/post_install";
my $queue  = "$FindBin::Bin/../scripts/queue_postrun_task";

## no critic (ValuesAndExpressions::ProhibitFiletest_rwxRWX)
ok( -x $script && -x $queue, 'post_install and queue_postrun_task are there and executable' );

# The perl that runs this test, which has DBD::SQLite.  The shebang names the
# system perl of a guest, and the machine that runs the tests need not have it
# there.
# What post_install gets on stdin, which is what make gives it on a guest.
my $make_stdin = q{};

sub post_install {
    my ( $db, @args ) = @_;
    local $ENV{POST_INSTALL_DB} = $db;
    IPC::Run3::run3( [ $^X, $script, @args ], \$make_stdin, \my $out, \my $err );
    return { status => $? >> 8, out => $out // q{}, err => $err // q{} };
}

sub rows {
    my ($db) = @_;
    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db", q{}, q{}, { RaiseError => 1 } );
    return $dbh->selectall_arrayref( 'SELECT slot, task, argv, ran, status FROM tasks ORDER BY id', { Slice => {} } );
}

# Queue each task, as [slot, task] or a task with no slot, and run the queue.
# Each task appends its own name to a file, so what ran is a list rather than a
# guess about output.
sub run_queue {
    my (@tasks) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    my $db  = "$dir/queue.db";
    my $ran = "$dir/ran";
    foreach my $task (@tasks) {
        my ( $slot, $command ) = ref $task ? @$task : ( undef, $task );
        my @argv = map { s/%RAN%/$ran/gr } ref $command ? @$command : ($command);
        local $ENV{POSTRUN_SLOT} = $slot;
        delete $ENV{POSTRUN_SLOT} unless defined $slot;
        my $queued = post_install( $db, '--queue', @argv );
        die "could not queue @argv: $queued->{err}" if $queued->{status};
    }

    my $r    = post_install($db);
    my $done = eval { File::Slurper::read_text($ran) } // q{};
    return { %$r, db => $db, ran => [ split( m/\n/, $done ) ] };
}

subtest 'every task runs, and the exit code is the answer at the end' => sub {
    my $r = run_queue( 'echo one >> %RAN%', 'echo two >> %RAN%' );
    is_deeply( $r->{ran}, [qw{one two}], 'both ran' );
    is( $r->{status}, 0, 'and it exits clean' );

    $r = run_queue( 'echo one >> %RAN%', 'false', 'echo three >> %RAN%' );
    is_deeply( $r->{ran}, [qw{one three}], 'a failing task does not stop the ones after it' );
    is( $r->{status}, 1, 'and the failure is still the exit code' );
    ok( index( $r->{err}, 'postrun FAILED: false' ) >= 0, 'saying which task it was' ) or diag $r->{err};
    like( $r->{out}, qr/^postrun:[ ]echo[ ]one[ ]>>/m, 'and each task says what it is as it starts' );
};

# A task that read stdin once ate the rest of a queue that the loop read from
# stdin.  On a tcms guest that was cpanm, and it took the service build and the
# ufw reload with it.  Deferred work has no input, so a task gets none.
subtest 'a task that reads stdin has nothing to read' => sub {
    $make_stdin = "for post_install, not for its tasks\n";
    my $r = run_queue( 'echo one >> %RAN%', 'cat >> %RAN%', 'echo three >> %RAN%' );
    $make_stdin = q{};
    is_deeply( $r->{ran}, [qw{one three}], 'the reader read nothing, and everything after it ran' ) or diag "out: $r->{out}\nerr: $r->{err}";
};

subtest 'the queue runs by slot, and in queued order within one' => sub {
    my $r = run_queue( [ 30, 'echo c >> %RAN%' ], [ 10, 'echo a >> %RAN%' ], [ 30, 'echo d >> %RAN%' ], 'echo e >> %RAN%', [ 20, 'echo b >> %RAN%' ] );
    is_deeply( $r->{ran}, [qw{a b c d e}], 'by slot, ties in the order queued, and a task with no slot last' );
};

# The shell of the makefile has already split and expanded the words of a task
# that comes as several arguments.  A second shell would split them again, and
# expand what the first one left literal.
subtest 'a task of several arguments runs as them, with no shell' => sub {
    my $r = run_queue( [ 5, [ '/bin/sh', '-c', 'printf "%s\n" "$0" >> "$1"', 'semi;colon $HOME `id`', '%RAN%' ] ] );
    is_deeply( $r->{ran},                                       ['semi;colon $HOME `id`'], 'each argument arrives as it was given' ) or diag "out: $r->{out}\nerr: $r->{err}";
    is_deeply( decode_json( rows( $r->{db} )->[0]{argv} )->[3], 'semi;colon $HOME `id`',   'and is kept as one, in a JSON array' );
};

subtest 'a task runs once, and the queue says how it went' => sub {
    my $r = run_queue( 'echo one >> %RAN%', 'exit 3' );

    my @rows = @{ rows( $r->{db} ) };
    is( scalar( grep { !defined $_->{ran} } @rows ), 0, 'every task is marked as run, the failed one too' );
    is_deeply( [ map { $_->{status} } @rows ], [ 0, 3 ], 'with what each exited with' );

    my $again = post_install( $r->{db} );
    is( $again->{status},                                              0,       'a second run is clean' );
    is( $again->{out},                                                 q{},     'and runs nothing again' );
    is( File::Slurper::read_text( $r->{db} =~ s{queue[.]db\z}{ran}r ), "one\n", 'so the tasks do not happen twice' );
};

subtest 'queue_postrun_task keeps the slot of its target, and the words of the task' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $db  = "$dir/queue.db";

    {
        local $ENV{POSTRUN_SLOT} = 7;
        is( post_install( $db, '--queue', qw{systemctl restart nginx} )->{status}, 0, 'it queues clean' );
    }
    delete local $ENV{POSTRUN_SLOT};
    post_install( $db, '--queue', 'echo by hand' );

    # Many writers at once, as make -j gives, each in a process of its own.
    local $ENV{POST_INSTALL_DB} = $db;
    my $writers = 'for n in $(seq 1 20); do POSTRUN_SLOT=$((100 + n)) "$0" "$1" --queue "echo writer $n" & done; wait';
    IPC::Run3::run3( [ 'bash', '-c', $writers, $^X, $script ], \undef, \undef, \my $err );

    my @rows = @{ rows($db) };
    is_deeply( [ @{ $rows[0] }{qw{slot task}} ], [ 7,       'systemctl restart nginx' ], 'the task with the slot the makefile exported, its words kept together' );
    is_deeply( [ @{ $rows[1] }{qw{slot task}} ], [ 999_999, 'echo by hand' ],            'and a task queued outside the makefile after every slot' );
    is( scalar( grep { $_->{slot} > 100 && $_->{task} =~ m/\Aecho[ ]writer[ ]\d+\z/ } @rows ), 20, 'twenty writers at once leave twenty tasks' ) or diag $err;

    local $ENV{POSTRUN_SLOT} = 'first';
    like( post_install( $db, '--queue', 'true' )->{err}, qr/POSTRUN_SLOT[ ]is[ ]'first',[ ]which[ ]is[ ]not[ ]a[ ]slot/, 'a slot that is not a number is refused' );
    like( post_install( $db, '--queue' )->{err}, qr/\Ausage:/, 'and so is nothing to queue' );
};

# The fragments call the wrapper, which runs post_install through its shebang,
# the system perl of a guest.
subtest 'queue_postrun_task is post_install --queue' => sub {
    IPC::Run3::run3( [qw{/usr/bin/perl -MDBD::SQLite -e1}], \undef, \undef, \undef );
    plan skip_all => '/usr/bin/perl here has no DBD::SQLite, which libdbd-sqlite3-perl gives a guest' if $?;

    my $db = tempdir( CLEANUP => 1 ) . '/queue.db';
    local $ENV{POST_INSTALL_DB} = $db;
    local $ENV{POSTRUN_SLOT}    = 5;
    IPC::Run3::run3( [ $queue, qw{echo from the wrapper} ], \undef, \undef, \my $err );
    is( $? >> 8,              0,                       'it queues clean' ) or diag $err;
    is( rows($db)->[0]{task}, 'echo from the wrapper', 'the task it was given' );
};

subtest 'nothing queued is nothing to do' => sub {
    my $r = post_install( tempdir( CLEANUP => 1 ) . '/never.db' );
    is( $r->{status}, 0, 'it exits clean rather than complaining' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
