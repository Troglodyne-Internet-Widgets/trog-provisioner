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
use File::Which();
use IPC::Run3();
use Cpanel::JSON::XS();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

my %GLOBALS = ( domain => 'bot.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', admin_user => 'bogus' );
my %BASE    = (
    bot                => 'test-bot',
    github_token       => 'ghp_x',
    claude_oauth_token => 'sk-x',
    spokes             => [ 'test-org/one', 'test-org/two' ],
    dashboard_password => 'not-the-password',
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
    is_deeply( $conf->{spokes},                                         $BASE{spokes},                      'with every spoke' );
    is_deeply( [ @{$conf}{qw{authorized_users owners poll_interval}} ], [ ['someone'], ['test-org'], 120 ], 'and who it obeys, what is ours, and the interval' );

    # The hash is what printf %s not-the-password | sha256sum prints.
    is_deeply( $conf->{auth}, { user => 'admin', password_sha256 => '77210af2f1758a49f5d167d60dd8404361f27d652d269625cc88309f2f0080b1' }, 'and basic authentication for the page, with the SHA-256 of the password' );
    is( $conf->{minion}, 'sqlite:/bogus/bot.test.test/clod-state/minion.db', 'and the database where the salvage puts it back' );
    unlike( File::Slurper::read_text("$dir/clod.conf"), qr/ghp_x|sk-x|not-the-password/, 'and no token, which goes in clod.env, and not the password itself' );
};

# App::Clod hashes the bytes that basic authentication sends, which a browser
# sends as UTF-8.  The hash is what printf %s on that password gives sha256sum.
subtest 'a password that is not ASCII is hashed as its UTF-8 bytes' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = recipe($dir);
    $r->generate_files( $dir, $r->validated( $r->takes(%GLOBALS), %BASE, dashboard_password => "p\N{LATIN SMALL LETTER A WITH DIAERESIS}ssw\N{LATIN SMALL LETTER O WITH DIAERESIS}rd" ) );
    my $conf = do "$dir/clod.conf";
    is( $conf->{auth}{password_sha256}, '46970bef70aced8123f0d5d094717e2a5cd412041e03b26376049fe65b2834a4', 'the hash is that of the UTF-8 bytes' ) or diag $@;
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

# App::Clod dies on create_repos without spoke_orgs, so the recipe refuses it
# first, and clod.conf is read by perl as App::Clod reads it.
subtest 'create_repos and follow_up_max reach clod.conf' => sub {
    my %org = ( %BASE, spoke_orgs => ['test-org'] );
    delete $org{spokes};

    my %conf;
    foreach my $case ( [ off => {} ], [ on => { create_repos => 1, follow_up_max => 0 } ], [ word => { create_repos => 'true', follow_up_max => 5 } ] ) {
        my ( $name, $opts ) = @$case;
        my $dir = tempdir( CLEANUP => 1 );
        my $r   = recipe($dir);
        $r->generate_files( $dir, $r->validated( $r->takes(%GLOBALS), %org, %$opts ) );
        $conf{$name} = do "$dir/clod.conf" or diag( $@, File::Slurper::read_text("$dir/clod.conf") );
    }
    is_deeply( [ $conf{off}{create_repos}, exists $conf{off}{follow_up_max} ], [ 0, !!0 ], 'unset, the bot makes no repository, and App::Clod keeps its own follow-up limit' );
    is_deeply( [ @{ $conf{on} }{qw{create_repos follow_up_max}} ],             [ 1, 0 ],   'set, the bot makes them, and a limit of 0 turns follow-ups off' );
    is_deeply( [ @{ $conf{word} }{qw{create_repos follow_up_max}} ],           [ 1, 5 ],   'and true in YAML is the same switch' );

    foreach my $refused ( [ { create_repos => 1 }, 'create_repos without spoke_orgs' ], [ { follow_up_max => -1 }, 'a negative follow_up_max' ] ) {
        my $r = recipe();
        ok( exception { $r->validated( $r->takes(%GLOBALS), %BASE, %{ $refused->[0] } ) }, "the recipe refuses $refused->[1]" );
    }
    my $r = recipe();
    is( exception { $r->validated( $r->takes(%GLOBALS), %BASE, create_repos => 0 ) }, undef, 'and takes create_repos off without spoke_orgs' );
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

# What cvtsudoers makes of a rendered sudoers file, rather than what the file
# looks like.  /usr/bin by name, because it is not on the PATH of every user.
my $cvtsudoers = File::Which::which('cvtsudoers') // File::Which::which('/usr/bin/cvtsudoers');

# A file that grants nothing comes out as nothing at all.
sub grants {
    my ($file) = @_;
    IPC::Run3::run3( [ $cvtsudoers, '-f', 'json', $file ], \undef, \my $out, \my $err );
    return { error => $err || "cvtsudoers exited $?" } if $?;
    return {}                                          if $out eq q{};
    return eval { Cpanel::JSON::XS::decode_json($out) } // { error => "not JSON: $out" };
}

subtest 'claude runs as the agent account' => sub {
    my %required = recipe()->required_recipes();
    is_deeply( { $required{claude}->( %GLOBALS, agent_user => 'test-agent' ) }, { restricted_user => 'test-agent' }, 'the claude recipe makes the account' );
    is_deeply( { $required{claude}->(%GLOBALS) },                               {},                                  'and makes none for a domain that names none' );

    my $dir    = tempdir( CLEANUP => 1 );
    my $r      = recipe($dir);
    my %got    = $r->validated( $r->takes( %GLOBALS, user => 'svc' ), %BASE, agent_user => 'test-agent' );
    my $claude = Provisioner::Cookbook->load( 'claude', distro => 'ubuntu' );
    is( $got{agent_home}, $claude->restricted_home( %GLOBALS, restricted_user => 'test-agent' ), 'in the home that the claude recipe gives it' );
    $r->generate_files( $dir, %got );
    my $conf = do "$dir/clod.conf";
    is( $conf->{claude}{run_as}, 'test-agent', 'and App::Clod runs claude as it' ) or diag $@;

    my $unit = File::Slurper::read_text("$dir/clod-worker.service");
    like( $unit, qr/^UMask=0007$/m, 'with a umask that leaves the files of a worktree to the group' );
    my $share = File::Slurper::read_text("$dir/clod-share.sh");
    like( $share, qr/^usermod[ ]-a[ ]-G[ ]'test-agent'[ ]'svc'$/m, 'and the worker in the group of the agent' );
    my $owners = qr{-o[ ]'svc'[ ]-g[ ]'test-agent'};
    like( $share, qr{^install[ ]-d[ ]$owners[ ]-m[ ]2770[ ]"\$workspace"$}m, 'which owns the workspace' );
    my $said   = $r->render(%got);
    my $queued = index( $said, "/bogus/bin/queue_postrun_task '/bogus/bot.test.test/clod-share.sh'" );
    ok( $queued >= 0 && $queued < index( $said, 'queue_postrun_task systemctl restart' ), 'in the postrun, after the claude recipe has made the account, and before the restart' );

  SKIP: {
        skip 'no cvtsudoers here', 2 unless $cvtsudoers;
        my $grants = grants("$dir/clod.sudoers");
        is_deeply(
            $grants->{User_Specs},
            [
                {
                    User_List  => [ { username   => 'svc' } ],
                    Host_List  => [ { hostname   => 'ALL' } ],
                    Cmnd_Specs => [ { runasusers => [ { username => 'test-agent' } ], Options => [ { authenticate => Cpanel::JSON::XS::false() }, { setenv => Cpanel::JSON::XS::true() } ], Commands => [ { command => 'ALL' } ] } ],
                }
            ],
            'sudo lets the worker run anything as the agent, with no password, and with the environment that it names'
        ) or diag explain $grants;
        is_deeply( $grants->{Defaults}, [ { Binding => [ { username => 'test-agent' } ], Options => [ { umask => '0007' } ] } ], 'with the umask 0007' ) or diag explain $grants;
    }

    my $plain = tempdir( CLEANUP => 1 );
    my $none  = recipe($plain);
    my %bare  = $none->validated( $none->takes( %GLOBALS, user => 'svc' ), %BASE );
    $none->generate_files( $plain, %bare );
    ok( !exists +( do "$plain/clod.conf" )->{claude}{run_as}, 'a domain that names no agent runs claude as the worker' );
  SKIP: {
        skip 'no cvtsudoers here', 1 unless $cvtsudoers;
        my $grants = grants("$plain/clod.sudoers");
        is_deeply( [ @{$grants}{qw{User_Specs Defaults error}} ], [ undef, undef, undef ], 'and its sudoers file, which sudo reads, grants nothing' ) or diag explain $grants;
    }

    my $dotted = recipe();
    like( exception { $dotted->validated( $dotted->takes( %GLOBALS, user => 'svc.dotted' ), %BASE ) }, qr/sudoers\.d/, 'a service user that would name a sudoers file that sudo skips is refused' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
