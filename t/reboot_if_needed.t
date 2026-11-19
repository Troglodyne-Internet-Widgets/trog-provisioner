#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/reboot_if_needed.t - scripts/reboot_if_needed: reboot when asked, never while a build or a check holds it, and log why

=cut

use Test::More;
use File::Temp qw{tempdir};
use File::Path qw{make_path remove_tree};
use IPC::Run3();
use File::Slurper();
use File::Slurper::Temp();
use Time::HiRes qw{time};

use FindBin;

my $script = "$FindBin::Bin/../scripts/reboot_if_needed";

# A file that a test runs, which the script under test finds by name.
sub executable {
    my ( $file, $text ) = @_;
    File::Slurper::Temp::write_text( $file, $text );
    chmod 0755, $file or die "$file: $!";
    return;
}

# Nothing here reboots or logs anything.  The script calls reboot and logger by
# name, so these stand in for them, first on the PATH, and write down the call.
my $dir      = tempdir( CLEANUP => 1 );
my $rebooted = "$dir/rebooted";
my $syslog   = "$dir/syslog";
make_path("$dir/bin");
executable( "$dir/bin/reboot", "#!/bin/sh\ntouch '$rebooted'\n" );
executable( "$dir/bin/logger", "#!/bin/sh\necho \"\$\@\" >> '$syslog'\n" );

my $required = "$dir/reboot-required";
my $holds    = "$dir/no-reboot";
my $checks   = "$dir/reboot-checks.d";
my $held     = "$dir/run/reboot-held";

# One run of the script: whether it rebooted, and what it logged.
sub run_once {
    my (%env) = @_;
    unlink $rebooted, $syslog;

    local $ENV{PATH}            = "$dir/bin:$ENV{PATH}";
    local $ENV{REBOOT_REQUIRED} = $required;
    local $ENV{NO_REBOOT_DIR}   = $holds;
    local $ENV{CHECKS_DIR}      = $checks;
    local $ENV{HOLD_LOG}        = $held;
    local @ENV{ keys %env }     = values %env;
    IPC::Run3::run3( [ 'bash', $script ], \undef, \my $out, \my $err );
    die "reboot_if_needed exited $?: $out$err" if $?;

    my $logged = -e $syslog ? File::Slurper::read_text($syslog) : '';
    return ( ( -e $rebooted ? 1 : 0 ), $logged );
}

sub reboots {
    my (%env) = @_;
    my ($did) = run_once(%env);
    return $did;
}

sub check {
    my ( $name, $body ) = @_;
    make_path($checks);
    executable( "$checks/$name", "#!/bin/sh\n$body\n" );
    return;
}

subtest 'nothing asked for a reboot' => sub {
    unlink $required;
    check( 'no', 'echo never; exit 1' );
    my ( $did, $logged ) = run_once();
    is( $did,    0,  'no reboot without reboot-required' );
    is( $logged, '', 'and nothing to log, whatever the checks say' );
    remove_tree($checks);
};

File::Slurper::Temp::write_text( $required, '' );

subtest 'an update asked for a reboot' => sub {
    my ( $did, $logged ) = run_once();
    is( $did, 1, 'with no checks directory, it reboots' );
    my $since = qr/required\ since\ \d{4}-\d\d-\d\d\ /;
    my $tag   = qr/^-t\ reboot_if_needed\ --\ /;
    like( $logged, qr/${tag}rebooting:\ $since.*no\ check\ objected$/m, 'and logs why' );

    check( 'yes', 'exit 0' );
    is( reboots(), 1, 'with a check that says yes, it reboots' );
};

subtest 'a check that says no holds the reboot' => sub {
    check( 'tcms-d.test', 'echo "2 Minion jobs running"; echo more; exit 1' );
    my ( $did, $logged ) = run_once();
    is( $did,    0,                                                                   'one no holds it' );
    is( $logged, "-t reboot_if_needed -- held: tcms-d.test: 2 Minion jobs running\n", 'and the log names the check and the first line of its reason' );

    check( 'relay-d.test', 'echo "this guest reboots only by hand"; exit 3' );
    ( $did, $logged ) = run_once();
    my $relay = 'relay-d.test: this guest reboots only by hand';
    my $tcms  = 'tcms-d.test: 2 Minion jobs running';
    like( $logged, qr/held:\ \Q$relay\E;\ \Q$tcms\E$/m, 'every check runs, and the log names each that holds it' );

    unlink "$checks/relay-d.test", "$checks/tcms-d.test";
    is( reboots(), 1, 'and once they say yes, it reboots' );
};

subtest 'a check that fails to answer holds the reboot' => sub {
    check( 'silent', 'exit 2' );
    my ( undef, $logged ) = run_once();
    like( $logged, qr/held:\ silent:\ exited\ 2\ with\ no\ reason$/m, 'a refusal with no reason gives its exit status' );
    unlink "$checks/silent";

    check( 'hung', 'sleep 30' );
    my $started = time;
    ( my $did, $logged ) = run_once( CHECK_TIMEOUT => 1 );
    is( $did, 0, 'a check that hangs holds it' );
    like( $logged, qr/held:\ hung:\ no\ answer\ in\ 1\ seconds$/m, 'and the log says it did not answer' );
    cmp_ok( time - $started, '<', 20, 'and the script does not wait for it' );
    unlink "$checks/hung";

    File::Slurper::Temp::write_text( "$checks/plain", "#!/bin/sh\nexit 0\n" );
    ( $did, $logged ) = run_once();
    is( $did, 0, 'a check that cannot run holds it' );
    like( $logged, qr/held:\ plain:\ not\ an\ executable\ file$/m, 'and the log says so' );
    unlink "$checks/plain";
};

subtest 'a hold is logged when it changes, and otherwise once an hour' => sub {
    unlink $held;
    check( 'busy', 'echo busy; exit 1' );
    my ( undef, $logged ) = run_once();
    like( $logged, qr/held:\ busy:\ busy/, 'the first hold is logged' );

    ( undef, $logged ) = run_once();
    is( $logged, '', 'the same hold five minutes later is not' );

    my $hour_ago = time - 3600;
    utime $hour_ago, $hour_ago, $held or die "$held: $!";
    ( undef, $logged ) = run_once();
    like( $logged, qr/held:\ busy:\ busy/, 'the same hold an hour later is' );

    check( 'busy', 'echo busier; exit 1' );
    ( undef, $logged ) = run_once();
    like( $logged, qr/held:\ busy:\ busier/, 'a hold with a new reason is logged at once' );

    unlink "$checks/busy";
    is( reboots(), 1, 'the reboot happens once the hold ends' );
    ok( !-e $held, 'and it forgets the hold, so the next one is logged at once' );
};

subtest 'a build holds reboots until it ends' => sub {
    make_path($holds);
    is( reboots(), 1, 'an empty hold directory holds nothing' );

    File::Slurper::Temp::write_text( "$holds/d.test", '' );
    is( reboots(), 0, 'a build in progress holds the reboot' );

    File::Slurper::Temp::write_text( "$holds/e.test", '' );
    unlink "$holds/d.test";
    is( reboots(), 0, 'one build ending does not release the hold of another' );

    unlink "$holds/e.test";
    is( reboots(), 1, 'and once the last build ends, it reboots' );
};

done_testing();
