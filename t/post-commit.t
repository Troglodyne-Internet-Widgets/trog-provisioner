#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/post-commit.t - git-hooks/post-commit refreshes the records for a commit, and
not for each commit that a rebase or a cherry-pick applies

=head1 DESCRIPTION

Each case runs the hook as git runs it, in a repository made for the test,
with a fake tests-covering first on PATH that records each call.

=cut

use Test::More;
use List::Util  qw{any};
use File::Temp  qw{tempdir};
use File::Copy  qw{copy};
use Time::HiRes qw{sleep time};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $dir  = tempdir( CLEANUP => 1 );
my $repo = "$dir/repo";
my $log  = "$dir/refreshes";
mkdir $repo        or die "Cannot make $repo: $!";
mkdir "$dir/bin"   or die "Cannot make $dir/bin: $!";
mkdir "$dir/hooks" or die "Cannot make $dir/hooks: $!";

copy( "$FindBin::Bin/../git-hooks/post-commit", "$dir/hooks/post-commit" ) or die "Cannot copy the hook: $!";
chmod 0755, "$dir/hooks/post-commit";

# Records the commit it was run for, so a case can wait for the call it expects.
File::Slurper::Temp::write_text( "$dir/bin/tests-covering", qq{#!/bin/sh\ngit rev-parse HEAD >> '$log'\n} );
chmod 0755, "$dir/bin/tests-covering";

# The pre-commit hook runs this test with GIT_DIR and GIT_INDEX_FILE set to the
# repository being committed to, and git obeys them over -C.  Without this, the
# git below commits, rebases and configures that repository, not the one here.
delete $ENV{$_} for grep { m/\AGIT_/ } keys %ENV;

local $ENV{PATH}                = "$dir/bin:$ENV{PATH}";
local $ENV{HOME}                = $dir;
local $ENV{GIT_CONFIG_NOSYSTEM} = 1;

my $git = sub {
    my (@args) = @_;
    my $said = q{};
    IPC::Run3::run3( [ 'git', '-C', $repo, @args ], \undef, \$said, \$said );
    die "git @args: $said" if $?;
    return $said;
};

# The hook runs the refresh in the background, so this waits for the call made
# for the commit at HEAD, and then returns every commit that was refreshed.
my $refreshed = sub {
    my $head     = $git->(qw{rev-parse HEAD});
    my $deadline = time + 10;
    my @calls;
    while ( time < $deadline ) {
        @calls = -e $log ? split /\n/, File::Slurper::read_text($log) : ();
        last if any { "$_\n" eq $head } @calls;
        sleep 0.05;
    }
    unlink $log;
    return scalar @calls;
};

my $commit = sub {
    my ( $file, $text ) = @_;
    File::Slurper::Temp::write_text( "$repo/$file", $text );
    $git->( 'add',            $file );
    $git->( qw{commit -q -m}, "Change $file" );
    return;
};

is_deeply( [ grep { m/\AGIT_/ && $_ ne 'GIT_CONFIG_NOSYSTEM' } sort keys %ENV ], [], 'no GIT_ variable reaches git from the caller' )
  or BAIL_OUT('git would work in the repository of the caller');

$git->(qw{init -q -b master});
chomp( my $top = $git->(qw{rev-parse --absolute-git-dir}) );
is( $top, "$repo/.git", 'git works in the repository made here, and in no other' ) or BAIL_OUT("git would work in $top");
$git->(qw{config user.name Tester});
$git->(qw{config user.email tester@test.test});
$git->( 'config', 'core.hooksPath', "$dir/hooks" );

subtest 'a commit is refreshed' => sub {
    $commit->( 'a', "one\n" );
    is( $refreshed->(), 1, 'once' );
};

subtest 'a rebase refreshes nothing while it applies its commits' => sub {
    $git->(qw{switch -q -c topic});
    $commit->( "t$_", "$_\n" ) for 1 .. 3;
    $refreshed->();

    $git->(qw{switch -q master});
    $commit->( 'b', "two\n" );
    $refreshed->();

    $git->(qw{rebase -q master topic});
    $commit->( 'c', "after\n" );
    is( $refreshed->(), 1, 'three commits rebased, and only the commit after them is refreshed' );
};

subtest 'a cherry-pick of several commits refreshes nothing while it applies them' => sub {
    $git->(qw{switch -q -c picked master});
    $git->(qw{cherry-pick topic~2..topic});
    $commit->( 'd', "after\n" );
    is( $refreshed->(), 1, 'two commits picked, and only the commit after them is refreshed' );
};

done_testing;
