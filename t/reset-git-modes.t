#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/reset-git-modes.t - scripts/reset_git_modes: put back the tracked modes, and keep every change of content

=cut

# Every filetest here is on a path this test just made in a temporary directory
# nothing else can see, so there is no window for it to be wrong in.
## no critic (ValuesAndExpressions::ProhibitFiletest_e, ValuesAndExpressions::ProhibitFiletest_d, ValuesAndExpressions::ProhibitFiletest_f, ValuesAndExpressions::ProhibitFiletest_rwxRWX)

use Test::More;
use Fcntl         qw{S_IXUSR};
use File::Temp    qw{tempdir};
use File::Slurper qw{read_text};
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/reset_git_modes";
ok( -x $script, 'reset_git_modes is there and executable' );

# A home that is not the account's own, so that no global configuration of the
# account that runs the test reaches git.
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME}                = $home;
local $ENV{GIT_CONFIG_NOSYSTEM} = 1;

sub run_in {
    my (@cmd) = @_;
    IPC::Run3::run3( \@cmd, \undef, \my $out, \my $err );
    return { rc => $? >> 8, said => ( $out // '' ) . ( $err // '' ) };
}

sub mode_of {
    my ($path) = @_;
    return sprintf '%04o', ( stat $path )[2] & oct('7777');
}

# A checkout with one executable and two plain files, committed.
sub checkout {
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/$_", "$_\n" ) for qw{tool plain edited};
    chmod 0755, "$dir/tool";
    chmod 0644, "$dir/plain", "$dir/edited";
    run_in( 'git', '-C', $dir, 'init', '-q' );
    run_in( 'git', '-C', $dir, 'add',  '.' );
    run_in( 'git', '-C', $dir, qw{-c user.name=t -c user.email=t@t commit -q -m one} );
    return $dir;
}

subtest 'a salvage that made every file executable is clean again' => sub {
    my $dir = checkout();
    chmod 0750, map { "$dir/$_" } qw{tool plain edited};
    isnt( run_in( 'git', '-C', $dir, 'status', '--porcelain' )->{said}, '', 'the setup is dirty' );

    my $r = run_in( $script, $dir );
    is( $r->{rc},                                                     0,       'not an error' );
    is( run_in( 'git', '-C', $dir, 'status', '--porcelain' )->{said}, '',      'git status is clean' );
    is( ( stat "$dir/plain" )[2] & S_IXUSR,                           0,       'a file that git tracks as 644 lost its execute bit' );
    is( ( stat "$dir/tool" )[2] & S_IXUSR,                            S_IXUSR, 'and one that git tracks as 755 has it' );
};

subtest 'a change of content stays, with its mode as it was found' => sub {
    my $dir = checkout();
    chmod 0750, map { "$dir/$_" } qw{tool plain edited};
    File::Slurper::Temp::write_text( "$dir/edited", "live edit\n" );

    is( run_in( $script, $dir )->{rc}, 0,             'not an error' );
    is( read_text("$dir/edited"),      "live edit\n", 'the edit is still there' );
    is( mode_of("$dir/edited"),        '0750',        'and its mode is not touched' );
    like( run_in( 'git', '-C', $dir, 'status', '--porcelain' )->{said}, qr/\A [ ]M[ ]edited\n \z/, 'and only that file is dirty' );
};

subtest 'a clean checkout, a directory that is not one, and a path that is not there' => sub {
    my $dir = checkout();
    is( run_in( $script, $dir )->{rc}, 0,      'a clean checkout is not an error' );
    is( mode_of("$dir/plain"),         '0644', 'and nothing moved' );

    my $plain = tempdir( CLEANUP => 1 );
    is( run_in( $script, $plain )->{rc},             0, 'a directory with no git in it is not an error' );
    is( run_in( $script, "$plain/not-there" )->{rc}, 0, 'and neither is a path that does not exist' );
};

done_testing;
