#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-perllsp.t - the vim plugins: pinned, fetched as tarballs,
and replaced rather than cloned over

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();

my $SHA = 'a' x 40;

sub recipe {
    return Provisioner::Cookbook->load( 'perllsp', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

sub rendered {
    my (%extra) = @_;
    return recipe()->render( admin_user => 'admin', script_dir => '/root/bin', %extra );
}

subtest 'the vim-lsp family, each pinned to a commit' => sub {
    my %opts = recipe()->validate();

    is_deeply( [ map { $_->{dir} } @{ $opts{plugins} } ], [qw{async asyncomplete-lsp.vim asyncomplete.vim vim-lsp}], 'all four, in directory order' );
    ok( !( grep { $_->{ref} !~ m/\A[0-9a-f]{40}\z/ } @{ $opts{plugins} } ), 'every one at a commit rather than a branch' );

    # On the members, so one more plugin is not four fewer.
    my %added = recipe()->validate( vim_plugins => { 'vim-surround' => { repo => 'tpope/vim-surround', ref => $SHA } } );
    is( scalar @{ $added{plugins} }, 5, 'naming another adds it to the defaults' );

    my %moved = recipe()->validate( vim_plugins => { 'vim-lsp' => { repo => 'prabirshrestha/vim-lsp', ref => $SHA } } );
    my ($lsp) = grep { $_->{dir} eq 'vim-lsp' } @{ $moved{plugins} };
    is( $lsp->{ref}, $SHA, 'and naming a default moves its pin' );
};

subtest 'what it will not take' => sub {
    like( exception { recipe()->validate( vim_plugins => { x => { repo => 'o/r', ref => 'master' } } ) }, qr/ref/, 'a branch, which moves' );
    like( exception { recipe()->validate( vim_plugins => { x => { repo => 'o/r' } } ) },                  qr/ref/, 'no commit at all' );

    # The fragment empties this directory before unpacking into it.
    like( exception { recipe()->validate( vim_plugins => { '..' => { repo => 'o/r', ref => $SHA } } ) }, qr/plain directory name/, 'a directory that is not one plain path component' );
};

subtest 'the fragment fetches each pinned tarball into an emptied directory' => sub {
    my $out   = rendered();
    my $start = '/home/admin/.vim/pack/lsp/start';

    unlike( $out, qr/git clone/, 'nothing is cloned' );

    my $ref = '2082d13bb195f3203d41a308b89417426a7deca1';

    # The four lines for one plugin, from its fetch on.
    my @lines = split( "\n", $out );
    my ($at)  = grep { index( $lines[$_], q{/async.vim/tar.gz/} ) >= 0 } 0 .. $#lines;
    my @async = @lines[ $at .. $at + 3 ];
    like( $async[0], qr{^curl -fsSL --retry 3 --retry-all-errors -o 'perllsp\.async\.tar\.gz' 'https://codeload\.github\.com/prabirshrestha/async\.vim/tar\.gz/$ref'$}, 'fetched as the pinned commit' );
    like( $async[1], qr{^rm -rf '\Q$start\E/async'$},                                                                                                                   'into a directory emptied first, so a re-provision does not fail on it' );
    like( $async[3], qr{^tar -xzf 'perllsp\.async\.tar\.gz' --strip-components=1 -C '\Q$start\E/async'$},                                                               'unpacked without the directory codeload wraps it in' );

    # Make eats a single dollar before the shell sees it.
    unlike( $out, qr/(?<!\$)\$(?!\$)/, 'and nothing in it is a make variable by accident' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
