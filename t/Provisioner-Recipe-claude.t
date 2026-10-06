#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-claude.t - what the claude recipe installs, and in what order

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Basename();
use File::Find();
use File::Path();
use IPC::Run3();
use Cpanel::JSON::XS();

use FindBin::libs;

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);

my %G = (
    domain      => 'agent.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'someadmin',
    user        => 'agent',
    modules     => [],
);

sub recipe { return Provisioner::Cookbook->load( 'claude', distro => 'ubuntu' )->new(%PROV) }

subtest 'the rtk release it installs' => sub {
    my %got = recipe()->validated(%G);
    like( $got{rtk_version}, qr/\Av\d+\.\d+\.\d+\z/, 'a tag by default' );

    my $said = recipe()->render( %G, rtk_version => 'v1.2.3' );
    like( $said, qr{releases/download/v1\.2\.3/rtk_1\.2\.3-1_}, 'the .deb of the tag it was given' );

    # dpkg names a version without the v, and the package adds its own -1.  A
    # mismatch here reinstalls on every provision rather than never.
    like( $said, qr/dpkg-query[^\n]*rtk/, 'the check asks dpkg what is installed' );
    like( $said, qr/=[ ]"1\.2\.3-1"/,     'against the version dpkg reports, which carries the package revision' );
};

# rtk edits the settings file rather than writing its own.  Installed before
# the recipe puts that file in place, its hook is overwritten by the next line
# and nothing says so.
subtest 'rtk is registered after the settings are installed' => sub {
    my $said = recipe()->render(%G);

    my ($settings) = $said =~ m/(.*claude\.settings\.json.*)/;
    ok( $settings, 'the settings file is installed' );

    my $mv_at   = index( $said, 'claude.settings.json' );
    my $init_at = index( $said, 'rtk init' );
    ok( $init_at > $mv_at, 'and rtk is registered afterwards' );

    like( $said, qr/rtk[ ]init[ ]-g[ ]--auto-patch/,                  'without questions, which a makefile has nobody to answer' );
    like( $said, qr/HOME='[^']*\/agent\.test\.test'[^\n]*rtk[ ]init/, 'into the home the agent runs out of' );
};

# Every provision replaces the settings file.  Run before the mv, the auto mode
# configuration goes into the file the mv then overwrites, and nothing says so.
subtest 'the auto mode configuration goes into the installed settings' => sub {
    my $said = recipe()->render(%G);

    my $run = q{/root/bin/claude_settings auto-mode '/opt/domains/agent.test.test/claude.auto-mode.json' '/opt/domains/agent.test.test/.claude/settings.json'};
    ok( index( $said, $run ) >= 0,                                                               'from the data directory of the domain, into its settings' ) or diag $said;
    ok( index( $said, 'claude_settings auto-mode' ) > index( $said, 'mv claude.settings.json' ), 'after the settings file is in place' );
};

subtest 'where it fetches from, and what the cache keeps' => sub {
    my @hosts = recipe()->fetch_hosts();
    ok( ( grep { $_ eq 'github.com' } @hosts ), 'the release comes from GitHub' );

    my @classes = recipe()->cache_classes();
    ok( ( grep { ( $_->{class} // q{} ) eq 'immutable' } @classes ), 'and a release asset is immutable to the cache' );
};

# The rendered settings, as JSON, for a guest running these modules.
sub settings_for {
    my (@modules) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    recipe()->generate_files( $dir, %G, modules => [@modules] );

    my $text = do { local ( @ARGV, $/ ) = "$dir/claude.settings.json"; <> }
      // q{};

    # Assigned rather than returned straight out of the eval: the profile wants
    # an eval whose value somebody looks at, and both callers here do.
    my $conf = eval { Cpanel::JSON::XS::decode_json($text) };
    return ( $text, $conf );
}

# A plugin whose marketplace this same file never declares loads nothing, and
# says nothing about it -- so the only place the mistake shows is here.  Asked
# of several guests rather than one, because the two ways in are different: the
# name is wrong on every guest, while the gating is only wrong on a guest
# missing one of the modules a marketplace is conditional on.
my %CASES = (
    'a guest with perl and perllsp' => [qw{perl perllsp claude}],
    'a guest with perl alone'       => [qw{perl claude}],
    'a guest with neither'          => [qw{claude}],
    'a guest with perllsp alone'    => [qw{perllsp claude}],
);

foreach my $what ( sort keys %CASES ) {
    subtest "every plugin enabled for $what comes from a marketplace it declares" => sub {
        my ( $text, $conf ) = settings_for( @{ $CASES{$what} } );

        ok( $conf, 'the settings render as valid JSON' ) or diag $text;
        return unless $conf;

        my %declared = map { $_ => 1 } keys %{ $conf->{extraKnownMarketplaces} // {} };
        my @orphans  = grep {
            my $at     = index( $_, '@' );
            my $market = $at >= 0 ? substr( $_, $at + 1 ) : q{};
            !$market || !$declared{$market}
        } keys %{ $conf->{enabledPlugins} // {} };

        is_deeply( \@orphans, [], 'no enabled plugin names a marketplace that is not there' )
          or diag 'declared: ' . join( ', ', sort keys %declared );
    };
}

# The plugins no gate covers, so a guest that runs this recipe and nothing else
# still gets them.  Each is named as its marketplace publishes it.
subtest 'the plugins every guest gets, whatever else it runs' => sub {
    my ( undef, $conf ) = settings_for(qw{claude});

    ok( $conf, 'the settings render as valid JSON' ) or return;
    foreach my $plugin (qw{perl-slop@troglodyne-marketplace simple-english@simple-english}) {
        ok( $conf->{enabledPlugins}{$plugin}, "$plugin is enabled" )
          or diag 'enabled: ' . join( ', ', sort keys %{ $conf->{enabledPlugins} // {} } );
    }
    is( $conf->{extraKnownMarketplaces}{'simple-english'}{source}{repo}, 'AminBlg/SimpleEnglish', 'and simple-english comes from where it is published' );
};

# Gated on the perl recipe by its name, and perllsp is a different name.
subtest 'the perl plugin is enabled only where the perl recipe runs' => sub {
    my ( undef, $with )    = settings_for(qw{perl claude});
    my ( undef, $without ) = settings_for(qw{perllsp claude});

    ok( $with->{enabledPlugins}{'perl-development@perigrin-marketplace'},     'a guest with perl gets it' );
    ok( !$without->{enabledPlugins}{'perl-development@perigrin-marketplace'}, 'a guest with perllsp and no perl does not' );
    ok( !$without->{extraKnownMarketplaces}{'perigrin-marketplace'},          'nor its marketplace' );
};

# The exit code of a command line, as the guest runs it, and what it said.
sub run_sh {
    my ($command) = @_;
    IPC::Run3::run3( [ '/bin/sh', '-c', $command ], \undef, \my $out, \my $err );
    return ( $? >> 8, $err );
}

# The command runs here, on a fake home, because what it lets through is the
# whole point of it.  A transcript that comes down is a secret in every backup.
subtest 'only the memories are staged for the salvage' => sub {
    my $install_dir = tempdir( CLEANUP => 1 );
    my $home        = "$install_dir/agent.test.test";
    my $project     = "$home/.claude/projects/-bogus-project";

    my %files = (
        "$project/memory/MEMORY.md"                                        => 'kept',
        "$project/memory/some-fact.md"                                     => 'kept',
        "$project/0123abcd-0000-0000-0000-000000000000.jsonl"              => 'transcript',
        "$project/0123abcd-0000-0000-0000-000000000000/tool-results/x.txt" => 'tool output',
        "$project/0123abcd-0000-0000-0000-000000000000/subagents/y.jsonl"  => 'transcript',
        "$home/.claude/projects/-other/memory/MEMORY.md"                   => 'kept',
    );
    foreach my $path ( sort keys %files ) {
        File::Path::make_path( File::Basename::dirname($path) );
        open( my $fh, '>', $path ) or die "Cannot write $path: $!";
        print {$fh} $files{$path};
        close($fh) or die "Cannot close $path: $!";
    }

    my @commands = recipe()->remote_prepare( $install_dir, 'agent.test.test' );
    is( scalar @commands, 1, 'one command' );
    my ( $rc, $err ) = run_sh( $commands[0] );
    is( $rc, 0, 'which succeeds' ) or diag "$commands[0]\n$err";

    my $staged = "$home/.claude-memory-salvage";
    my @got;
    File::Find::find( { no_chdir => 1, wanted => sub { push @got, $File::Find::name =~ s{\A\Q$staged\E/}{}r unless -d } }, $staged );
    is_deeply(
        [ sort @got ],
        [qw{projects/-bogus-project/memory/MEMORY.md projects/-bogus-project/memory/some-fact.md projects/-other/memory/MEMORY.md}],
        'the memory of every project, and no transcript or tool output'
    );

    unlink "$project/memory/some-fact.md" or die "Cannot unlink: $!";
    run_sh( $commands[0] );
    ok( !-e "$staged/projects/-bogus-project/memory/some-fact.md", 'a memory that was deleted is not salvaged again' );

    File::Path::remove_tree("$home/.claude/projects");
    is( ( run_sh( $commands[0] ) )[0], 0, 'a guest whose projects are gone is not a failure' );
    ok( !-e "$staged/projects", 'and the copy staged before goes with them' );

    my %remote = recipe()->remote_files( $install_dir, 'agent.test.test' );
    is( $remote{"$home/.claude-memory-salvage/"}, 'claude/memory/', 'the staged copy is what comes down' );

    my $empty = tempdir( CLEANUP => 1 );
    File::Path::make_path("$empty/agent.test.test/.claude");
    my ($none) = recipe()->remote_prepare( $empty, 'agent.test.test' );
    is( ( run_sh($none) )[0], 0, 'a guest with no projects is not a failure' );
    ok( !-e "$empty/agent.test.test/.claude-memory-salvage/projects", 'and stages nothing' );
};

subtest 'the memories go back where the agent reads them' => sub {
    my %restores = recipe()->restores(%G);
    is_deeply(
        \%restores,
        { '/opt/domains/agent.test.test/.claude/projects' => { from => '/opt/domains/agent.test.test/claude/memory/projects', owner => 'someadmin:someadmin' } },
        'into .claude/projects of the domain, for the admin'
    );
};

Test::NoWarnings::had_no_warnings();

done_testing();
