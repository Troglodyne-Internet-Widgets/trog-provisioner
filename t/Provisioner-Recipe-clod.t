#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-clod.t - what the clod recipe hands its dependencies, and the configuration it writes

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

my %GLOBALS = ( domain => 'bot.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', admin_user => 'bogus' );
my %BASE    = (
    bot                       => 'test-bot',
    github_token              => 'ghp_x',
    claude_oauth_token        => 'sk-x',
    spokes                    => [ 'test-org/one', 'test-org/two' ],
    dashboard_password_sha256 => 'a' x 64,
);

sub recipe {
    my ($dir) = @_;
    return Provisioner::Cookbook->load( 'clod', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir // '/nonexistent',
        distro        => 'ubuntu',
    );
}

subtest 'the perl recipe installs the checkout, and the modules of the spokes after it' => sub {
    my %required = recipe()->required_recipes();
    my %perl     = $required{perl}->(%GLOBALS);
    is_deeply( $perl{cpan_deps}, [ { dzil => '/bogus/bot.test.test/App-Clod' } ], 'with no spoke_modules, the checkout alone' );

    my %more = $required{perl}->( %GLOBALS, spoke_modules => ['Test2::V0'] );
    is_deeply( $more{cpan_deps}[1], { install => ['Test2::V0'] }, 'and the modules of the spokes, when there are some' );

    my %proxy = $required{nginxproxy}->(%GLOBALS);
    is( $proxy{proxy_uri}, 'run/clod.sock', 'nginxproxy serves the socket of the daemon' );
};

# App::Clod evaluates the configuration as perl, so this evaluates it too.
subtest 'clod.conf is perl that App::Clod reads' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = recipe($dir);
    $r->generate_files( $dir, $r->validated( $r->takes(%GLOBALS), %BASE, authorized_users => ['someone'], owners => ['test-org'], poll_interval => 120 ) );
    my $conf = do "$dir/clod.conf";
    my $why  = $@ || File::Slurper::read_text("$dir/clod.conf");
    ok( ref $conf eq 'HASH', 'it evaluates to a hash' ) or diag $why;
    is_deeply( $conf->{spokes},                                         $BASE{spokes},                                    'with every spoke' );
    is_deeply( [ @{$conf}{qw{authorized_users owners poll_interval}} ], [ ['someone'], ['test-org'], 120 ],               'and who it obeys, what is ours, and the interval' );
    is_deeply( $conf->{auth},                                           { user => 'admin', password_sha256 => 'a' x 64 }, 'and basic authentication for the page' );
    is( $conf->{minion}, 'sqlite:/bogus/bot.test.test/clod-state/minion.db', 'and the database where the salvage puts it back' );
    unlike( File::Slurper::read_text("$dir/clod.conf"), qr/ghp_x|sk-x/, 'and no token, which goes in clod.env' );
};

# The prompt is free text, so it holds whatever could end a perl string or
# interpolate into one.  The HTML is there because Xslate escapes for HTML.
subtest 'the spoke runs get their own tools, prompt and tool spokes' => sub {
    my $dir    = tempdir( CLEANUP => 1 );
    my $r      = recipe($dir);
    my $smiley = chr 0x263a;
    my $prompt = qq{Say "hi" and 'bye'.\nCost: \$5 \@list %h \\' C:\\path\\\n<b>&amp;</b> $smiley\n};
    my @tools  = ( 'Bash(bin/provision:*)', 'Bash(make test >/dev/null & $HOME @x)' );
    $r->generate_files( $dir, $r->validated( $r->takes(%GLOBALS), %BASE, extra_tools => \@tools, spoke_prompt => $prompt, tool_spokes => ['test-org/tool'] ) );
    my $conf = do "$dir/clod.conf";
    ok( ref $conf eq 'HASH', 'clod.conf still evaluates to a hash' ) or diag( $@, File::Slurper::read_text("$dir/clod.conf") );
    is_deeply( $conf->{claude}, { extra_tools => \@tools }, 'with the extra tools in the claude section, where App::Clod reads them' );
    is( $conf->{spoke_prompt}, $prompt, 'and the prompt, character for character' );
    is_deeply( $conf->{tool_spokes}, ['test-org/tool'], 'and the tool spokes' );

    my $plain = tempdir( CLEANUP => 1 );
    my $none  = recipe($plain);
    $none->generate_files( $plain, $none->validated( $none->takes(%GLOBALS), %BASE ) );
    my $bare = do "$plain/clod.conf";
    is_deeply( [ $bare->{claude}{extra_tools}, $bare->{tool_spokes}, exists $bare->{spoke_prompt} ], [ [], [], !!0 ], 'without them, no extra tools, no tool spokes and no prompt' ) or diag $@;
};

subtest 'an extra tool is one permission rule, on one line' => sub {
    foreach my $bad ( "Bash(x)\n", q{Bash(it's)}, 'Bash("x")', "Bash(a\nb)", 'Bash(a\\b)', 'Bash()', 'Bash(x) y', '1Bash' ) {
        my $r = recipe();
        ok( exception { $r->validated( $r->takes(%GLOBALS), %BASE, extra_tools => [$bad] ) }, 'the recipe refuses ' . ( $bad =~ s/\n/\\n/gr ) );
    }
    my $r = recipe();
    is( exception { $r->validated( $r->takes(%GLOBALS), %BASE, extra_tools => [ 'WebFetch', 'mcp__srv__tool', 'Bash(git push:*)' ] ) }, undef, 'and takes a tool, or a tool and its argument' );
};

subtest 'an organization can stand in for the list of spokes' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = recipe($dir);
    my %org = %BASE;
    delete $org{spokes};
    $r->generate_files( $dir, $r->validated( $r->takes(%GLOBALS), %org, spoke_orgs => ['test-org'] ) );
    my $conf = do "$dir/clod.conf";
    is_deeply( [ @{$conf}{qw{spokes spoke_orgs}} ], [ [], ['test-org'] ], 'clod.conf names the organization and no spokes' ) or diag $@;
    my $fresh = recipe();
    ok( exception { $fresh->validated( $fresh->takes(%GLOBALS), %org ) }, 'and with neither, the recipe refuses' );
};

subtest 'the daemon listens on the socket that nginx proxies to' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = recipe($dir);
    $r->generate_files( $dir, $r->validated( $r->takes(%GLOBALS), %BASE ) );
    my $unit   = File::Slurper::read_text("$dir/clod.service");
    my $listen = qr{daemon[ ]-l[ ]http\+unix://};
    my $path   = qr{%%2Fbogus%%2Fbot\.test\.test%%2Frun%%2Fclod\.sock};
    like( $unit, qr{$listen$path$}m, 'the path is URL-encoded, with each % doubled for systemd' );
};

subtest 'the database comes back where clod.conf says it is' => sub {
    my %restores = recipe()->restores(%GLOBALS);
    is_deeply( [ keys %restores ], ['/bogus/bot.test.test/clod-state/minion.db'], 'one restore, to the database' );
    my ($salvaged) = values %{ { recipe()->remote_files( '/bogus', 'bot.test.test' ) } };
    is( $restores{'/bogus/bot.test.test/clod-state/minion.db'}{from}, "/bogus/bot.test.test/${salvaged}minion.db", 'from the salvage' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
