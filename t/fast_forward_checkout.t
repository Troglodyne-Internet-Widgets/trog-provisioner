#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/fast_forward_checkout.t - scripts/fast_forward_checkout: a kept checkout
moves to the tip of its branch only when that cannot lose anything

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;

my $script = "$FindBin::Bin/../scripts/fast_forward_checkout";

# git with a fixed identity, and no configuration of the person who runs the
# test.
local $ENV{GIT_CONFIG_GLOBAL}                        = '/dev/null';
local $ENV{GIT_CONFIG_NOSYSTEM}                      = 1;
local @ENV{qw{GIT_AUTHOR_NAME GIT_COMMITTER_NAME}}   = ('Tester') x 2;
local @ENV{qw{GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL}} = ('tester@test.test') x 2;

sub git {
    my ( $dir, @args ) = @_;
    IPC::Run3::run3( [ 'git', '-C', $dir, @args ], \undef, \my $out, \my $err );
    die "git @args: $err" if $?;
    chomp $out;
    return $out;
}

sub commit {
    my ( $dir, $file, $text ) = @_;
    File::Slurper::Temp::write_text( "$dir/$file", $text );
    git( $dir, 'add',                 $file );
    git( $dir, qw{commit --quiet -m}, "write $file" );
    return git( $dir, 'rev-parse', 'HEAD' );
}

# An upstream on main with one commit, a checkout cloned from it, and then a
# second commit upstream that the checkout does not have.  The checkout ignores
# main.cfg, as tCMS does.
sub setup {
    my $root     = tempdir( CLEANUP => 1 );
    my $upstream = "$root/upstream";
    mkdir $upstream or die "mkdir: $!";
    git( $upstream, qw{init --quiet --initial-branch=main} );
    File::Slurper::Temp::write_text( "$upstream/.gitignore", "main.cfg\n" );
    git( $upstream, 'add', '.gitignore' );
    commit( $upstream, 'lib.pm', "one\n" );
    IPC::Run3::run3( [ qw{git clone --quiet}, $upstream, "$root/checkout" ], \undef, \undef, \my $err );
    die "git clone: $err" if $?;
    my $tip = commit( $upstream, 'lib.pm', "two\n" );
    return ( $upstream, "$root/checkout", $tip );
}

sub fast_forward {
    my ( $checkout, $upstream, $branch ) = @_;
    IPC::Run3::run3( [ $script, $checkout, $upstream, $branch // 'main' ], \undef, \my $out, \my $err );
    return ( $? >> 8, $out . $err );
}

subtest 'a clean checkout on the branch moves to its tip, and keeps what git ignores' => sub {
    my ( $upstream, $checkout, $tip ) = setup();
    File::Slurper::Temp::write_text( "$checkout/main.cfg", "live\n" );
    my ( $status, $said ) = fast_forward( $checkout, $upstream );
    is( $status,                               0,    'it exits 0' )                               or diag $said;
    is( git( $checkout, 'rev-parse', 'HEAD' ), $tip, 'the checkout is at the tip of the branch' ) or diag $said;
    is( File::Slurper::read_text("$checkout/main.cfg"), "live\n", 'and the configuration that git ignores is as it was' );
    like( $said, qr/fast-forwarded[ ]from/, 'and the log says that it moved' );

    ( $status, $said ) = fast_forward( $checkout, $upstream );
    is( git( $checkout, 'rev-parse', 'HEAD' ), $tip, 'a second run leaves it at the tip' );
    like( $said, qr/already[ ]at/, 'and says so' );
};

subtest 'a checkout with an edit to a tracked file stays where it is' => sub {
    my ( $upstream, $checkout ) = setup();
    my $head = git( $checkout, 'rev-parse', 'HEAD' );
    File::Slurper::Temp::write_text( "$checkout/lib.pm", "edited\n" );
    my ( $status, $said ) = fast_forward( $checkout, $upstream );
    is( $status,                                      0,          'it exits 0' );
    is( git( $checkout, 'rev-parse', 'HEAD' ),        $head,      'the checkout did not move' );
    is( File::Slurper::read_text("$checkout/lib.pm"), "edited\n", 'and the edit is still there' );
    like( $said, qr/left[ ]as[ ]it[ ]is:[ ]tracked[ ]files/, 'and the log says why' );
};

subtest 'a checkout with a commit of its own stays where it is' => sub {
    my ( $upstream, $checkout ) = setup();
    my $local = commit( $checkout, 'local.pm', "mine\n" );
    my ( $status, $said ) = fast_forward( $checkout, $upstream );
    is( $status,                               0,      'it exits 0' );
    is( git( $checkout, 'rev-parse', 'HEAD' ), $local, 'the checkout keeps its own commit, and nothing merged into it' );
    like( $said, qr/not[ ]a[ ]fast-forward/, 'and the log says why' );
};

subtest 'a checkout on another branch stays where it is' => sub {
    my ( $upstream, $checkout ) = setup();
    git( $checkout, qw{switch --quiet -c private} );
    my $head = git( $checkout, 'rev-parse', 'HEAD' );
    my ( $status, $said ) = fast_forward( $checkout, $upstream );
    is( $status,                               0,     'it exits 0' );
    is( git( $checkout, 'rev-parse', 'HEAD' ), $head, 'the checkout did not move' );
    like( $said, qr/on[ ]private,[ ]not[ ]main/, 'and the log names both branches' );
};

subtest 'a repository that cannot be fetched leaves the checkout, and the build goes on' => sub {
    my ( $upstream, $checkout ) = setup();
    my $head = git( $checkout, 'rev-parse', 'HEAD' );
    my ( $status, $said ) = fast_forward( $checkout, "$upstream/../nonexistent" );
    is( $status,                               0,     'it exits 0' );
    is( git( $checkout, 'rev-parse', 'HEAD' ), $head, 'the checkout did not move' );
    like( $said, qr/could[ ]not[ ]fetch/, 'and the log says why' );
};

subtest 'a directory with no checkout is left to the clone' => sub {
    my $empty = tempdir( CLEANUP => 1 );
    my ($status) = fast_forward( "$empty/tCMS", '/nonexistent', 'main' );
    is( $status, 0, 'it exits 0' );
    ok( !-e "$empty/tCMS", 'and makes nothing' );
};

had_no_warnings();
done_testing;
