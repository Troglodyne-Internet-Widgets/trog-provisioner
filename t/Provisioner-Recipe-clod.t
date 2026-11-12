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
use File::Slurper::Temp();
use File::Which();
use File::Find();
use Test::MockModule qw{strict};
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
    is_deeply( $perl{cpan_deps}, [ { dzil => '/bogus/bot.test.test/App-Clod' }, { install => [qw{App::cpanoutdated Perl::Critic Perl::Tidy Devel::NYTProf}] } ], 'with no spoke_modules, the checkout, cpan-outdated, which clod deps needs, and the programs that a run may use' );

    my %more = $required{perl}->( %GLOBALS, spoke_modules => ['Test2::V0'] );
    is_deeply( $more{cpan_deps}[2], { install => ['Test2::V0'] }, 'and the modules of the spokes, when there are some' );

    my %proxy = $required{nginxproxy}->(%GLOBALS);
    is( $proxy{proxy_uri}, 'run/clod.sock', 'nginxproxy serves the socket of the daemon' );

    is_deeply( { $required{loccount}->(%GLOBALS) }, {}, 'and loccount is installed, for the Code tab of the health page, as its defaults have it' );
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

subtest 'the local lib that the bot upgrades its modules in' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = recipe($dir);
    my %got = $r->validated( $r->takes( %GLOBALS, user => 'svc' ), %BASE );
    $r->generate_files( $dir, %got );
    my $lib = '/bogus/bot.test.test/perl5';

    my $conf = do "$dir/clod.conf";
    is( $conf->{local_lib}, $lib, 'App::Clod keeps its modules in the local lib' ) or diag $@;
    is_deeply( $conf->{restart_units}, [qw{clod-bot.test.test.service clod-worker-bot.test.test.service}], 'and restarts both units after an update' );
    foreach my $unit (qw{clod.service clod-worker.service}) {
        my $text = File::Slurper::read_text("$dir/$unit");
        like( $text, qr{^Environment=PERL5LIB=\Q$lib\E/lib/perl5$}m,              "$unit loads the modules of the local lib first" );
        like( $text, qr{^Environment=PATH=\Q$lib\E/bin:/opt/perl5/current/bin:}m, 'and finds its programs first' );
    }

    # The script, run with a runuser that prints what it was asked to run.
    my $bin = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$bin/runuser", qq{#!/bin/sh\nprintf '%s\\n' "\$@"\n} );
    chmod 0755, "$bin/runuser" or die "chmod: $!";
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    IPC::Run3::run3( [ '/bin/sh', "$dir/clod-deps.sh" ], \undef, \my $said, \my $err );
    is( $? >> 8, 0, 'the script runs' ) or diag $err;
    my @argv = split m/\n/, $said;
    is_deeply( [ @argv[ 0 .. 2 ] ], [qw{-u svc --}], 'as the service user, who owns the local lib' );
    ok( ( grep { $_ eq "PERL5LIB=$lib/lib/perl5" } @argv ), 'with the local lib first' );
    is_deeply( [ @argv[ -3 .. -1 ] ], [ '/bogus/bot.test.test/App-Clod/script/clod', qw{deps install} ], 'and runs clod deps install' );

    my $fragment = $r->render(%got);
    my $owner    = qr{-o[ ]'svc'[ ]-g[ ]'bogus'};
    like( $fragment, qr{^install[ ]-d[ ]$owner[ ]-m[ ]0750[ ]'\Q$lib\E'$}m, 'the fragment makes the local lib for the service user' );
    is( $conf->{agent_lib}, '/bogus/bot.test.test/agent-perl5', 'App::Clod keeps the tools of the agent in the agent lib' );
    my $agent_lib = qr{[ ]-m[ ]2750[ ]'/bogus/bot\.test\.test/agent-perl5'$}m;
    like( $fragment, qr{^install[ ]-d[ ]-o[ ]'svc'[ ]-g[ ]'bogus'$agent_lib}m, 'which, with no agent, takes the group of the admin' );
    my $with       = recipe( tempdir( CLEANUP => 1 ) );
    my %agent      = $with->validated( $with->takes( %GLOBALS, user => 'svc' ), %BASE, agent_user => 'test-agent' );
    my $with_agent = $with->render(%agent);
    unlike( $with_agent, qr{-g[ ]'test-agent'}, 'and with one, the fragment names no group of the agent, because the claude target makes the account later' );
    like( $with_agent, qr{^install[ ]-d[ ]-o[ ]'svc'[ ]-g[ ]'bogus'$agent_lib}m, 'but makes the agent lib with the group of the admin' );
    my $agent_dir = tempdir( CLEANUP => 1 );
    $with->generate_files( $agent_dir, %agent );
    like(
        File::Slurper::read_text("$agent_dir/clod-share.sh"),
        qr{^install[ ]-d[ ]-o[ ]'svc'[ ]-g[ ]'test-agent'$agent_lib}m,
        'and the postrun gives it to the group of the agent, which may then read it'
    );
    my $share = index( $with_agent, "queue_postrun_task '/bogus/bot.test.test/clod-share.sh'" );
    my $deps  = index( $with_agent, "queue_postrun_task '/bogus/bot.test.test/clod-deps.sh'" );
    ok( $share >= 0 && $share < $deps,                                        'before it fills the agent lib' );
    ok( $deps < index( $with_agent, 'queue_postrun_task systemctl restart' ), 'which it does before the units start' );
};

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

    # sudo logs each variable that it passes, with its value, so the token
    # goes to the agent as a file, and claude reads it through clod-claude.sh.
    is( $conf->{claude}{bin}, '/bogus/bot.test.test/clod-claude.sh', 'and through the wrapper that brings the token of the agent' );
    unlike( File::Slurper::read_text("$dir/clod.env"), qr/CLAUDE_CODE_OAUTH_TOKEN/, 'so the worker has no Claude token' );
    is( File::Slurper::read_text("$dir/clod-agent.token"), 'sk-x', 'the token file holds the token alone' );
    my $handed = "install -o 'test-agent' -g 'test-agent' -m 0400 '/bogus/bot.test.test/clod-agent.token' '$got{agent_home}/.claude-token'";
    ok( ( grep { $_ eq $handed } split m/\n/, $share ), 'and the postrun gives it to the agent alone' ) or diag $share;

    # The wrapper, with a home of its own and a claude that says what it got.
    my $home = tempdir( CLEANUP => 1 );
    my $bin  = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$bin/claude", qq{#!/bin/sh\nprintf '%s|%s\\n' "\$CLAUDE_CODE_OAUTH_TOKEN" "\$*"\n} );
    chmod 0755, "$bin/claude";
    my $wrapper = File::Slurper::read_text("$dir/clod-claude.sh") =~ s/\Q$got{agent_home}\E/$home/gr;
    File::Slurper::Temp::write_text( "$home/wrapper", $wrapper );
    my $run = sub {
        local $ENV{PATH} = "$bin:/usr/bin:/bin";
        delete local $ENV{CLAUDE_CODE_OAUTH_TOKEN};
        IPC::Run3::run3( [ 'sh', "$home/wrapper", qw{-p --verbose} ], \undef, \my $out, \my $err );
        return ( $? >> 8, $out );
    };
    my ( $failed, undef ) = $run->();
    isnt( $failed, 0, 'without the token file, the wrapper runs no claude' );
    File::Slurper::Temp::write_text( "$home/.claude-token", 'sk-agent' );
    my ( $status, $out ) = $run->();
    is_deeply( [ $status, $out ], [ 0, "sk-agent|-p --verbose\n" ], 'with it, claude gets the token of the agent, and every argument' );

    my $plain = tempdir( CLEANUP => 1 );
    my $none  = recipe($plain);
    my %bare  = $none->validated( $none->takes( %GLOBALS, user => 'svc' ), %BASE );
    $none->generate_files( $plain, %bare );
    ok( !exists +( do "$plain/clod.conf" )->{claude}{run_as}, 'a domain that names no agent runs claude as the worker' );
    like( File::Slurper::read_text("$plain/clod.env"), qr/^CLAUDE_CODE_OAUTH_TOKEN=sk-x$/m, 'with the Claude token in the environment of the worker' );
  SKIP: {
        skip 'no cvtsudoers here', 1 unless $cvtsudoers;
        my $grants = grants("$plain/clod.sudoers");
        is_deeply( [ @{$grants}{qw{User_Specs Defaults error}} ], [ undef, undef, undef ], 'and its sudoers file, which sudo reads, grants nothing' ) or diag explain $grants;
    }

    my $dotted = recipe();
    like( exception { $dotted->validated( $dotted->takes( %GLOBALS, user => 'svc.dotted' ), %BASE ) }, qr/sudoers\.d/, 'a service user that would name a sudoers file that sudo skips is refused' );
};

# THE SYSTEM PACKAGES in Provisioner::Recipe::clod.  The installer runs here,
# with a fake packager in place of its command, which says what it was given.
subtest 'the installer of the system packages installs plain names, and refuses anything else' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = recipe($dir);
    my %got = $r->validated( $r->takes( %GLOBALS, user => 'svc' ), %BASE );
    $r->generate_files( $dir, %got );
    my $installer = '/usr/local/sbin/clod-install-packages';

    my $conf = do "$dir/clod.conf";
    is_deeply( $conf->{system_packages}, { packager => 'deb', installer => $installer }, 'clod.conf names the packager of the distribution, and the installer' ) or diag $@;

    my %required = $r->required_recipes();
    my %sudo     = $required{servicesudo}->(%GLOBALS);
    is( $sudo{commands}[-1], $installer, 'the service user may run it as root with any arguments' );
    my @lines = split m/\n/, $r->render(%got);
    is_deeply( [ grep { $_ eq "install -o root -g root -m 0755 clod-install-packages '$installer'" } @lines ], ["install -o root -g root -m 0755 clod-install-packages '$installer'"], 'and the fragment installs it for root, mode 0755' );

    my $bin = tempdir( CLEANUP => 1 );
    my $log = "$bin/argv";
    File::Slurper::Temp::write_text( "$bin/packager", qq{#!/bin/sh\nprintf '%s\\n' "\$@" > '$log'\necho the packager said this\nexit \${FAKE_EXIT:-0}\n} );
    chmod 0755, "$bin/packager" or die "chmod: $!";

    my $deb = Provisioner::Packager->named('deb');
    my $run = sub {
        my (@names) = @_;
        unlink $log;
        my $shim = q{my $f = shift; do $f or die $@ || $!; @main::INSTALL = (shift); exit main(@ARGV)};
        IPC::Run3::run3( [ $^X, '-e', $shim, "$dir/clod-install-packages", "$bin/packager", @names ], \undef, \my $out, \my $err );
        return ( $? >> 8, $out, $err, -e $log ? [ split m/\n/, File::Slurper::read_text($log) ] : undef );
    };

    my $shown = q{do $ARGV[0] or die $@ || $!; print join("\n", $main::NAME, @main::INSTALL, '--', @main::UPDATE), "\n"};
    IPC::Run3::run3( [ $^X, '-e', $shown, "$dir/clod-install-packages" ], \undef, \my $rendered, \my $broken );
    is_deeply( [ split m/\n/, $rendered ], [ $deb->package_name, $deb->install_command, '--', $deb->update_command('{sources}') ], 'the installer holds the name rule and the commands of the packager' ) or diag $broken;

    my ( $status, $out, $err, $argv ) = $run->(qw{ffmpeg libmagic-dev g++});
    is( $status, 0, 'a plain name is installed' ) or diag $err;
    is_deeply( $argv, [qw{ffmpeg libmagic-dev g++}], 'with every name, in order, after the command' );
    is( $out, "the packager said this\n", 'and it prints what the packager printed' );

    {
        local $ENV{FAKE_EXIT} = 100;
        ( $status, undef, undef, $argv ) = $run->('ffmpeg');
        is( $status, 100, 'and exits with the status of the packager' );
    }

    foreach my $bad ( qw{ffmpeg- -y --purge foo=1.2 foo/sid foo:i386 ./foo.deb F Foo}, 'two names', "ffmpeg\n", q{} ) {
        ( $status, $out, $err, $argv ) = $run->( 'git', $bad );
        is_deeply( [ $status, $argv ], [ 2, undef ], 'a call with ' . ( $bad =~ s/\n/\\n/r ) . ' in it is refused whole, and runs no packager' );
        like( $err, qr/not[ ]a[ ]plain[ ]deb[ ]package[ ]name.*installed[ ]nothing/, 'and says why on stderr' ) or diag $err;
    }
    ( $status, undef, $err, $argv ) = $run->();
    is_deeply( [ $status, $argv ], [ 2, undef ], 'a call that names no package is refused' );
    like( $err, qr/name[ ]the[ ]deb[ ]packages/, 'and says so' );

    # The apt-get of the guest is the link that scripts/serial_apt is under, so the real command, not the fake.
    my $scripts = tempdir( CLEANUP => 1 );
    my $through = tempdir( CLEANUP => 1 );
    my $other   = recipe($through);
    my %serial  = $other->validated( $other->takes( %GLOBALS, script_dir => $scripts, user => 'svc' ), %BASE );
    $other->generate_files( $through, %serial );
    mkdir "$scripts/serial-apt" or die "mkdir: $!";
    File::Slurper::Temp::write_text( "$scripts/serial-apt/apt-get", qq{#!/bin/sh\nprintf '%s\\n' "\$DEBIAN_FRONTEND" "\$@" > '$log'\n} );
    chmod 0755, "$scripts/serial-apt/apt-get" or die "chmod: $!";
    unlink $log;
    IPC::Run3::run3( [ $^X, '-e', q{my $f = shift; do $f or die $@ || $!; exit main(@ARGV)}, "$through/clod-install-packages", 'ffmpeg' ], \undef, \my $serial_out, \my $serial_err );
    my @apt = -e $log ? split( m/\n/, File::Slurper::read_text($log) ) : ();
    is_deeply( [ @apt[ 0, 1, -1 ] ], [qw{noninteractive install ffmpeg}], 'the install runs the apt-get of serial_apt, so that it waits for any other apt of the guest' ) or diag $serial_err;

    my $generic = 'Provisioner::Recipe::clod'->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => $dir, distro => 'ubuntu' );
    like( exception { $generic->validated( $generic->takes(%GLOBALS), %BASE ) }, qr/does[ ]not[ ]say[ ]which[ ]packager/, 'a distribution with no subclass of the recipe says that it has no packager' );
};

# The sources of the installer, with a fake packager for the install and the
# update, keys that gpg makes here, and a fetch that answers from them.
subtest 'the installer adds a source whose key has its fingerprint, and refuses every other' => sub {
    my $gpg = File::Which::which('gpg');
    plan skip_all => 'no gpg here, which the installer reads the keys with' unless $gpg;

    my $dir = tempdir( CLEANUP => 1 );
    my $r   = recipe($dir);
    $r->generate_files( $dir, $r->validated( $r->takes( %GLOBALS, user => 'svc' ), %BASE ) );

    # Two keys, and a file that holds both.
    my $home = tempdir( CLEANUP => 1 );
    my %fpr;
    foreach my $who (qw{good other}) {
        IPC::Run3::run3( [ $gpg, '--homedir', $home, qw{--batch --passphrase}, q{}, '--quick-gen-key', "$who <$who\@test.test>", qw{ed25519 sign never} ], \undef, \my $o, \my $e );
        is( $?, 0, "gpg makes the key $who" ) or diag $e;
        IPC::Run3::run3( [ $gpg, '--homedir', $home, qw{--batch --armor --export},          "$who\@test.test" ], \undef, "$home/$who.asc", \$e );
        IPC::Run3::run3( [ $gpg, '--homedir', $home, qw{--batch --with-colons --show-keys}, "$home/$who.asc" ],  \undef, \my $colons,      \$e );
        ( $fpr{$who} ) = $colons =~ m/^fpr:+([[:xdigit:]]{40}):/m;
    }
    File::Slurper::Temp::write_text( "$home/both.asc", File::Slurper::read_text("$home/good.asc") . File::Slurper::read_text("$home/other.asc") );

    my $bin = tempdir( CLEANUP => 1 );
    foreach my $step (qw{install update}) {
        File::Slurper::Temp::write_text( "$bin/$step", qq{#!/bin/sh\nprintf '%s\\n' "\$@" > '$bin/$step.argv'\nexit \${FAKE_\U$step\E_EXIT:-0}\n} );
        chmod 0755, "$bin/$step" or die "chmod: $!";
    }

    my %keys = map { ( "https://keys.test.test/$_.asc" => "$home/$_.asc" ) } qw{good other both};
    my $apt  = tempdir( CLEANUP => 1 );
    my $run  = sub {
        my ( $sources, @names ) = @_;
        unlink glob "$bin/*.argv";
        my $file = "$bin/sources.jsonl";
        File::Slurper::Temp::write_text( $file, join q{}, map { ref $_ ? Cpanel::JSON::XS->new->canonical->encode($_) . "\n" : $_ } @$sources );
        my $shim = q{
            my ( $f, $conf ) = splice @ARGV, 0, 2;
            do $f or die $@ || $!;
            my $c = JSON::PP::decode_json($conf);
            $main::APT     = $c->{apt};
            @main::GPG     = ( $c->{gpg} );
            @main::INSTALL = ( $c->{install} );
            @main::UPDATE  = ( $c->{update}, '{sources}' );
            $main::FETCH = sub {
                my $path = $c->{keys}{ $_[0] } // return { success => 0, status => 404 };
                return { success => 1, status => 200, content => do { local ( @ARGV, $/ ) = $path; <> } };
            };
            exit main(@ARGV);
        };
        my $conf = Cpanel::JSON::XS::encode_json( { apt => $apt, gpg => $gpg, install => "$bin/install", update => "$bin/update", keys => \%keys } );
        IPC::Run3::run3( [ $^X, '-e', $shim, "$dir/clod-install-packages", $conf, '--sources-file', $file, @names ], \undef, \my $out, \my $err );
        my %ran = map { ( $_ => -e "$bin/$_.argv" ? [ split m/\n/, File::Slurper::read_text("$bin/$_.argv") ] : undef ) } qw{install update};
        return ( $? >> 8, $err, \%ran );
    };
    my $written = sub {
        my %files;
        File::Find::find( { no_chdir => 1, wanted => sub { $files{ '/etc/apt' . substr( $_, length $apt ) } = File::Slurper::read_text($_) unless -d } }, $apt );
        return %files;
    };

    my %source = (
        name        => 'vendor',
        uri         => 'https://archive.test.test/apt',
        suites      => ['noble'],
        components  => ['main'],
        key         => 'https://keys.test.test/good.asc',
        fingerprint => lc $fpr{good},
        pin         => { priority => 600, packages => 'vendor-*' },
    );

    # Every way that a source can be wrong, refused before anything is written.
    my @bad = (
        [ 'a key with another fingerprint',      { %source, fingerprint => $fpr{other} },                                qr/is[ ]$fpr{good},[ ]not[ ]$fpr{other}/ ],
        [ 'a file of two keys',                  { %source, key         => 'https://keys.test.test/both.asc' },          qr/is[ ]\S+[ ]and[ ]\S+,[ ]not/ ],
        [ 'a key that does not fetch',           { %source, key         => 'https://keys.test.test/none.asc' },          qr/answered[ ]404/ ],
        [ 'a name that is a path',               { %source, name        => '../vendor' },                                qr/its[ ]name[ ]is[ ]not[ ]one/ ],
        [ 'a uri that is not http',              { %source, uri         => 'file:///bogus' },                            qr/its[ ]uri[ ]is[ ]not[ ]one/ ],
        [ 'a uri that ends a line of apt',       { %source, uri         => "https://archive.test.test/\nTrusted: yes" }, qr/its[ ]uri[ ]is[ ]not[ ]one/ ],
        [ 'a suite with a space',                { %source, suites      => ['noble main'] },                             qr/its[ ]suites[ ]is[ ]not[ ]one/ ],
        [ 'no suite',                            { %source, suites      => [] },                                         qr/its[ ]suites[ ]is[ ]not[ ]one/ ],
        [ 'a pin that is not a number',          { %source, pin         => { priority => 'high' } },                     qr/its[ ]pin[ ]is[ ]not[ ]one/ ],
        [ 'a field that a source does not have', { %source, trusted     => 'yes' },                                      qr/it[ ]has[ ]trusted/ ],
        [ 'no fingerprint',                      { map { $_ eq 'fingerprint' ? () : ( $_ => $source{$_} ) } keys %source }, qr/it[ ]has[ ]no[ ]fingerprint/ ],
        [ 'a line that is not JSON',             "not json\n",                                                              qr/line[ ]1[ ]\N*[ ]it[ ]is[ ]not[ ]JSON/ ],
    );
    foreach my $case (@bad) {
        my ( $what,   $bad, $why ) = @$case;
        my ( $status, $err, $ran ) = $run->( [$bad], 'vendor-tool' );
        is_deeply( [ $status, $ran, { $written->() } ], [ 2, { install => undef, update => undef }, {} ], "$what is refused, and nothing is written or run" );
        like( $err, $why, 'and it says why' ) or diag $err;
    }
    my ( $status, $err, $ran ) = $run->( [ \%source, \%source ], 'vendor-tool' );
    is( $status, 2, 'two sources of one name are refused' );

    ( $status, $err, $ran ) = $run->( [ \%source ], 'vendor-tool' );
    is( $status, 0, 'a source whose key has its fingerprint is added' ) or diag $err;
    my $deb  = Test::MockModule->new('Provisioner::Packager::Deb');
    my $good = File::Slurper::read_text("$home/good.asc");
    $deb->redefine( fetch => sub { return { success => 1, status => 200, content => $good } } );
    my %plain = %source;
    delete $plain{fingerprint};
    is_deeply( { $written->() }, { map { ( $_->{path} => $_->{content} ) } Provisioner::Packager::Deb->files( \%plain ) }, 'with the files that first boot writes for it' );
    is( sprintf( '%04o', ( stat "$apt/sources.list.d/vendor.sources" )[2] & oct 7777 ), '0644', 'which every account may read' );
    is_deeply( $ran->{update},  ["$apt/sources.list.d/vendor.sources"], 'then it updates that source, which {sources} in the command stands for' ) or diag explain $ran;
    is_deeply( $ran->{install}, ['vendor-tool'],                        'and installs' );

    ( $status, $err, $ran ) = $run->( [ \%source ], 'vendor-tool' );
    is( $status, 0, 'a source that is there already, the same, is no reason to refuse' ) or diag $err;

    File::Slurper::Temp::write_text( "$apt/sources.list.d/vendor.sources", "Types: deb\nURIs: https://bogus.test.test\n" );
    ( $status, $err, $ran ) = $run->( [ \%source ], 'vendor-tool' );
    is_deeply( [ $status, $ran->{install} ], [ 2, undef ], 'but a file of that name with other content is not replaced' );
    like( $err, qr/is[ ]there[ ]already/, 'and it says so' );
    unlink "$apt/sources.list.d/vendor.sources";

    local $ENV{FAKE_UPDATE_EXIT} = 100;
    ( $status, $err, $ran ) = $run->( [ \%source ], 'vendor-tool' );
    is_deeply( [ $status, $ran->{install} ], [ 100, undef ], 'an update that fails installs nothing, with the status of the update' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
