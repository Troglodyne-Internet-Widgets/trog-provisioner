#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/post-commit.t - the hooks in git-hooks/ refresh the records after a commit, a
pull and a rebase, and not for each commit that a rebase or a cherry-pick
applies

=head1 DESCRIPTION

Each case runs the hooks as git runs them, in a repository made for the test,
with a fake tests-covering first on PATH that records each call.

=cut

use Test::More;
use List::Util  qw{any};
use File::Temp  qw{tempdir};
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

# refresh-coverage puts the bin of the built perl first on PATH, and a
# tests-covering installed there would run in place of the fake below.  So the
# copy names this bin in its place.
foreach my $path (qw{git-hooks/post-commit git-hooks/post-merge git-hooks/post-rewrite git-hooks/refresh-coverage}) {
    my $name = $path =~ s{\A.*/}{}r;
    my $hook = File::Slurper::read_text("$FindBin::Bin/../$path");
    if ( $name eq q{refresh-coverage} ) {
        $hook =~ s{/opt/perl5/current/bin}{$dir/bin}g or die "refresh-coverage no longer names /opt/perl5/current/bin";
    }
    File::Slurper::Temp::write_text( "$dir/hooks/$name", $hook );
    chmod 0755, "$dir/hooks/$name";
}

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

# git in the repository $where.
my $git_in = sub {
    my ( $where, @args ) = @_;
    my $said = q{};
    IPC::Run3::run3( [ 'git', '-C', $where, @args ], \undef, \$said, \$said );
    die "git @args: $said" if $?;
    return $said;
};
my $git = sub { return $git_in->( $repo, @_ ) };

# The hook runs the refresh in the background, so this waits for the call made
# for the commit at HEAD of $where, by default the repository, and then returns
# every commit that was refreshed.
my $refreshed = sub {
    my ($where)  = @_;
    my $head     = $git_in->( $where // $repo, qw{rev-parse HEAD} );
    my $deadline = time + 10;
    my $read     = sub { return -e $log ? split /\n/, File::Slurper::read_text($log) : () };
    my @calls;
    while ( time < $deadline ) {
        @calls = $read->();
        last if any { "$_\n" eq $head } @calls;
        sleep 0.05;
    }

    # A refresh that an earlier hook started can still be on its way, so count
    # only once the log has stopped growing.
    my $seen = -1;
    while ( @calls != $seen && time < $deadline ) {
        $seen = @calls;
        sleep 0.3;
        @calls = $read->();
    }
    unlink $log;
    return scalar @calls;
};

# Commits $file with $text in $where, by default the repository.
my $commit = sub {
    my ( $file, $text, $where ) = @_;
    $where //= $repo;
    File::Slurper::Temp::write_text( "$where/$file", $text );
    $git_in->( $where, 'add',            $file );
    $git_in->( $where, qw{commit -q -m}, "Change $file" );
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
    is( $refreshed->(), 1, 'three commits rebased, and refreshed once, by post-rewrite when the rebase ends' );
    $commit->( 'c', "after\n" );
    is( $refreshed->(), 1, 'and the commit after them once' );
};

subtest 'a cherry-pick of several commits refreshes nothing while it applies them' => sub {
    $git->(qw{switch -q -c picked master});
    $git->(qw{cherry-pick topic~2..topic});
    $commit->( 'd', "after\n" );
    is( $refreshed->(), 1, 'two commits picked, and only the commit after them is refreshed' );
};

subtest 'an amend is refreshed once' => sub {
    $commit->( 'e', "first\n" );
    $refreshed->();
    File::Slurper::Temp::write_text( "$repo/e", "amended\n" );
    $git->( 'add', 'e' );
    $git->(qw{commit -q --amend --no-edit});
    is( $refreshed->(), 1, 'by post-commit, and not again by post-rewrite' );
};

# A clone that takes the hooks, and that pulls from the repository.
my $clone = "$dir/clone";
$git_in->( $dir,   qw{clone -q -b master}, $repo, $clone );
$git_in->( $clone, qw{config user.name Tester} );
$git_in->( $clone, qw{config user.email tester@test.test} );
$git_in->( $clone, 'config', 'core.hooksPath', "$dir/hooks" );

subtest 'a pull that brings commits in is refreshed' => sub {
    $git->(qw{switch -q master});
    $commit->( 'f', "upstream\n" );
    $refreshed->();

    $git_in->( $clone, qw{pull -q --no-rebase} );
    is( $refreshed->($clone), 1, 'once, by post-merge, when it fast-forwards' );

    $commit->( 'g', "upstream\n" );
    $refreshed->();
    $commit->( 'h', "local\n", $clone );
    $refreshed->($clone);
    $git_in->( $clone, qw{pull -q --rebase} );
    is( $refreshed->($clone), 1, 'and once, by post-rewrite, when a pull --rebase puts a local commit on top' );
};

done_testing;
