#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/claude_settings.t - scripts/claude_settings: what each command puts in the
settings, and what it leaves alone

=cut

use Test::More;
use Test::Fatal qw{exception};
use Fcntl       qw{S_IMODE};
use File::Temp  qw{tempdir};
use File::Path  qw{make_path};
use Cpanel::JSON::XS();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/claude_settings";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $JSON = Cpanel::JSON::XS->new->canonical;

my %SETTINGS = (
    enabledPlugins => { 'perl-slop@troglodyne-marketplace' => Cpanel::JSON::XS::true },
    hooks          => { PreToolUse                         => [ { matcher => 'Bash' } ] },
);
my %FRAGMENT = ( environment => [ 'Organization: $org', 'Trusted repo: $repo' ] );

sub write_file {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or BAIL_OUT("Cannot write $path: $!");
    print {$fh} $text;
    close $fh or BAIL_OUT("Cannot close $path: $!");
    return;
}

sub read_file {
    my ($path) = @_;
    return do { local ( @ARGV, $/ ) = $path; <> };
}

# A home with the settings the recipe installs, 0640 so that a rewrite which
# forgets the mode shows.
sub home {
    my (%settings) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/settings.json", $JSON->encode( { %SETTINGS, %settings } ) );
    chmod 0640, "$dir/settings.json" or BAIL_OUT("Cannot chmod: $!");
    return $dir;
}

sub settings_in {
    my ($dir) = @_;
    return $JSON->decode( read_file("$dir/settings.json") );
}

sub run { my (@args) = @_; return Trog::ClaudeSettings::main(@args) }

subtest 'auto-mode: a domain without a fragment keeps its settings as they were' => sub {
    my $dir    = home();
    my $before = read_file("$dir/settings.json");

    is( run( 'auto-mode', "$dir/claude.auto-mode.json", "$dir/settings.json" ), 0,       'exits 0' );
    is( read_file("$dir/settings.json"),                                        $before, 'and does not touch the settings' );
};

subtest 'auto-mode: a fragment becomes autoMode, and the rest stays' => sub {
    my $dir = home();
    write_file( "$dir/claude.auto-mode.json", $JSON->encode( {%FRAGMENT} ) );

    is( run( 'auto-mode', "$dir/claude.auto-mode.json", "$dir/settings.json" ), 0, 'exits 0' );
    my $got = settings_in($dir);
    is_deeply( $got->{autoMode}, {%FRAGMENT}, 'autoMode is the fragment' );

    # rtk puts its hook in this file, and the template puts the plugins there.
    # Either one lost says nothing on the guest until a plugin is missing.
    is_deeply( $got->{enabledPlugins}, $SETTINGS{enabledPlugins}, 'the plugins stay' );
    is_deeply( $got->{hooks},          $SETTINGS{hooks},          'and so do the hooks' );
};

# A second provision runs the command against settings that already carry it.
subtest 'auto-mode: a second run replaces autoMode rather than merging into it' => sub {
    my $dir = home( autoMode => { environment => ['old'] } );
    write_file( "$dir/claude.auto-mode.json", $JSON->encode( {%FRAGMENT} ) );

    run( 'auto-mode', "$dir/claude.auto-mode.json", "$dir/settings.json" );
    is_deeply( settings_in($dir)->{autoMode}, {%FRAGMENT}, 'only the new fragment is there' );
};

subtest 'auto-mode: a fragment it cannot use stops the build and leaves the settings' => sub {
    foreach my $case ( [ 'not JSON' => '{ environment' ], [ 'not an object' => '["a list"]' ] ) {
        my ( $what, $text ) = @$case;
        my $dir = home();
        write_file( "$dir/claude.auto-mode.json", $text );
        my $before = read_file("$dir/settings.json");

        like( exception { run( 'auto-mode', "$dir/claude.auto-mode.json", "$dir/settings.json" ) }, qr/claude[.]auto-mode[.]json/, "$what: dies naming the file" );
        is( read_file("$dir/settings.json"), $before, "$what: the settings are as they were" );
    }
};

# The clones of admincode, and what else lives beside them.
sub basedir_with {
    my (@repos) = @_;
    my $base = tempdir( CLEANUP => 1 );
    make_path("$base/$_/.git") for @repos;
    make_path("$base/not-a-repo");

    # The basedir a repository itself, which .*/.git matches as ./.git.
    make_path("$base/.git");
    write_file( "$base/a-file", "\n" );
    return $base;
}

subtest 'add-repos: each clone becomes an additional directory' => sub {
    my $base = basedir_with(qw{beta alpha .github});
    my $dir  = home();

    is( run( 'add-repos', $base, "$dir/settings.json" ), 0, 'exits 0' );
    my $got = settings_in($dir);
    is_deeply( $got->{permissions}{additionalDirectories}, [ "$base/.github", "$base/alpha", "$base/beta" ], 'the repositories and nothing else under the basedir, a name with a leading dot too' );
    is_deeply( $got->{enabledPlugins},                     $SETTINGS{enabledPlugins},                        'and the rest of the settings stay' );
};

subtest 'add-repos: what is there already stays, once' => sub {
    my $base = basedir_with(qw{alpha});
    my $dir  = home( permissions => { additionalDirectories => [ '/bogus/elsewhere', "$base/alpha" ], allow => ['Bash(prove:*)'] } );

    run( 'add-repos', $base, "$dir/settings.json" );
    run( 'add-repos', $base, "$dir/settings.json" );
    my $got = settings_in($dir)->{permissions};
    is_deeply( $got->{additionalDirectories}, [ '/bogus/elsewhere', "$base/alpha" ], 'a directory the admin added stays, and a clone is not listed twice' );
    is_deeply( $got->{allow},                 ['Bash(prove:*)'],                     'and so do the other permissions' );
};

subtest 'add-repos: a basedir that is not there stops the task' => sub {
    my $dir = home();
    like( exception { run( 'add-repos', '/bogus/nowhere', "$dir/settings.json" ) }, qr{/bogus/nowhere}, 'naming it' );
};

# A .claude as rtk init -g leaves it: a CLAUDE.md that imports RTK.md.
sub claude_dir {
    my ($claude_md) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/CLAUDE.md", $claude_md ) if defined $claude_md;
    return $dir;
}

my $RULES = "# Shell commands\n\nUnroll the loops.\n";

subtest 'instructions: a domain without a fragment keeps its CLAUDE.md as it was' => sub {
    my $dir = claude_dir("\@RTK.md\n");

    is( run( 'instructions', "$dir/claude.CLAUDE.md", "$dir/CLAUDE.md" ), 0,            'exits 0' );
    is( read_file("$dir/CLAUDE.md"),                                      "\@RTK.md\n", 'and does not touch CLAUDE.md' );
    ok( !-e "$dir/OPERATOR.md", 'or write OPERATOR.md' );
};

subtest 'instructions: the fragment is imported, and the import of rtk stays' => sub {
    my $dir = claude_dir("\@RTK.md\n");
    write_file( "$dir/claude.CLAUDE.md", $RULES );

    is( run( 'instructions', "$dir/claude.CLAUDE.md", "$dir/CLAUDE.md" ), 0,                           'exits 0' );
    is( read_file("$dir/OPERATOR.md"),                                    $RULES,                      'OPERATOR.md holds the fragment' );
    is( read_file("$dir/CLAUDE.md"),                                      "\@RTK.md\n\@OPERATOR.md\n", 'and CLAUDE.md imports it after RTK.md' );
};

# A second provision runs the command against a home that already has it.
subtest 'instructions: a second run replaces the fragment and imports it once' => sub {
    my $dir = claude_dir("\@RTK.md\n");
    write_file( "$dir/claude.CLAUDE.md", "old\n" );
    run( 'instructions', "$dir/claude.CLAUDE.md", "$dir/CLAUDE.md" );
    write_file( "$dir/claude.CLAUDE.md", $RULES );
    run( 'instructions', "$dir/claude.CLAUDE.md", "$dir/CLAUDE.md" );

    is( read_file("$dir/OPERATOR.md"), $RULES,                      'OPERATOR.md holds the new fragment' );
    is( read_file("$dir/CLAUDE.md"),   "\@RTK.md\n\@OPERATOR.md\n", 'and CLAUDE.md imports it once' );
};

subtest 'instructions: a CLAUDE.md that is missing or has no last newline' => sub {
    my $none = claude_dir();
    write_file( "$none/claude.CLAUDE.md", $RULES );
    run( 'instructions', "$none/claude.CLAUDE.md", "$none/CLAUDE.md" );
    is( read_file("$none/CLAUDE.md"), "\@OPERATOR.md\n", 'a home without CLAUDE.md gets one that imports the fragment' );

    my $bare = claude_dir('@RTK.md');
    write_file( "$bare/claude.CLAUDE.md", $RULES );
    run( 'instructions', "$bare/claude.CLAUDE.md", "$bare/CLAUDE.md" );
    is( read_file("$bare/CLAUDE.md"), "\@RTK.md\n\@OPERATOR.md\n", 'and the import goes on a line of its own after a last line with no newline' );
};

subtest 'instructions: a rewrite keeps the mode of CLAUDE.md' => sub {
    my $dir = claude_dir("\@RTK.md\n");
    chmod 0640, "$dir/CLAUDE.md" or BAIL_OUT("Cannot chmod: $!");
    write_file( "$dir/claude.CLAUDE.md", $RULES );

    run( 'instructions', "$dir/claude.CLAUDE.md", "$dir/CLAUDE.md" );
    is( sprintf( '%04o', S_IMODE( ( stat "$dir/CLAUDE.md" )[2] ) ), '0640', 'the mode' );
};

# The postrun task runs as root, after the claude recipe gave the file to the
# admin.  Root is not needed to see the owner kept: the file is already ours.
subtest 'a rewrite keeps the owner and the mode of the settings' => sub {
    my $dir    = home();
    my @before = ( stat "$dir/settings.json" )[ 2, 4, 5 ];

    run( 'add-repos', basedir_with(qw{alpha}), "$dir/settings.json" );
    my @after = ( stat "$dir/settings.json" )[ 2, 4, 5 ];
    is( sprintf( '%04o', S_IMODE( $after[0] ) ), '0640', 'the mode' );
    is_deeply( [ @after[ 1, 2 ] ], [ @before[ 1, 2 ] ], 'the owner and the group' );
};

subtest 'it wants a command it knows and both paths' => sub {
    like( exception { run( 'auto-mode', 'only-one' ) }, qr/usage:/, 'one path is a usage error' );
    like( exception { run(qw{bogus a b}) },             qr/usage:/, 'so is a command it does not know' );
    like( exception { run( 'add-repos', q{}, 'b' ) },   qr/usage:/, 'and an empty path' );
};

done_testing();
