#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-github.t - what the github recipe accepts, refuses and
fills in, and what koan and admincode ask of it

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);

my %G = (
    domain      => 'bot.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'someadmin',
    user        => 'koan',
);

sub recipe { return Provisioner::Cookbook->load( 'github', distro => 'ubuntu' )->new(%PROV) }

subtest 'the account it configures' => sub {
    my %got = recipe()->validated(%G);
    is( $got{account}, 'koan', 'the service user of the domain, when nothing names one' );

    %got = recipe()->validated( %G, account => 'someadmin' );
    is( $got{account}, 'someadmin', 'and the account the configuration names, when it does' );

    # A guest whose operator logs in by hand wants the CLI and no login, so
    # neither half is required and neither is invented.
    ok( !exists $got{github_user}, 'a domain that names no GitHub account gets none' );
    is( $got{git_protocol}, 'https', 'and clones over https, which a token authenticates' );
};

subtest 'half a login is refused' => sub {
    like(
        exception { recipe()->validated( %G, github_user => 'bot' ) },
        qr/github_user[ ]and[ ]github_token[ ]go[ ]together/,
        'an account with no token is refused'
    );
    like(
        exception { recipe()->validated( %G, github_token => 'ghp_x' ) },
        qr/github_user[ ]and[ ]github_token[ ]go[ ]together/,
        'and a token with no account'
    );

    ok( !exception { recipe()->validated( %G, github_user => 'bot', github_token => 'ghp_x' ) }, 'both together are fine' );
};

# gh authenticates with a token and never with a key, so this recipe has no
# business holding one.  Provisioner::Recipe::git does, and that is what
# t/Provisioner-Recipe-git.t is about.
subtest 'the key is not this recipe to give' => sub {
    like(
        exception { recipe()->validated( %G, ssh_identity => 1 ) },
        qr/Properties[ ]not[ ]allowed:[ ]ssh_identity/,
        'asking this one for a key is refused'
    );

    my %placed = recipe()->guest_secrets( '/opt/domains', 'bot.test.test', github_token => 'ghp_x' );
    is_deeply( [ keys %placed ], [], 'and it places nothing from the store' );

    # The host keys are the part of ssh that even a login-only guest needs, and
    # they come from the recipe that owns them.
    my %required = recipe()->required_recipes(%G);
    ok( ref $required{git} eq 'CODE', 'it requires git' );

    my %asked = $required{git}->(%G);
    is_deeply( $asked{accounts}, { koan => { hosts => ['github.com'] } }, 'for the host keys of github.com, under the account it logs in' );
    ok( !$asked{accounts}{koan}{ssh_identity}, 'and asks for no key: whatever wanted the login decides that' );
};

subtest 'the login state it renders' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = Provisioner::Cookbook->load( 'github', distro => 'ubuntu' )->new( %PROV, output_dir => $dir );

    $r->generate_files( $dir, %G, github_user => 'bot', github_token => 'ghp_x', git_protocol => 'ssh' );
    my $hosts = do { local ( @ARGV, $/ ) = "$dir/github.hosts.yml"; <> }
      // q{};

    like( $hosts, qr/^\s+user:[ ]bot$/m,          'it names the account' );
    like( $hosts, qr/^\s+oauth_token:[ ]ghp_x$/m, 'and the token gh reads' );
    like( $hosts, qr/^\s+git_protocol:[ ]ssh$/m,  'and the protocol it was told to clone over' );

    # A second object, because a recipe memoizes what validate made of its
    # options: the same one asked twice answers with the first configuration.
    my $https = Provisioner::Cookbook->load( 'github', distro => 'ubuntu' )->new( %PROV, output_dir => $dir );
    $https->generate_files( $dir, %G, github_user => 'bot', github_token => 'ghp_x' );

    $hosts = do { local ( @ARGV, $/ ) = "$dir/github.hosts.yml"; <> }
      // q{};
    like( $hosts, qr/^\s+git_protocol:[ ]https$/m, 'which is https unless something says otherwise' );
};

subtest 'the fragment does only what it was asked for' => sub {
    my $bare = recipe()->render(%G);
    unlike( $bare, qr/hosts\.yml/, 'a domain that asked for no login gets none written' );

    my $login = recipe()->render( %G, github_user => 'bot', github_token => 'ghp_x' );
    like( $login, qr/install\s[^\n]*github\.hosts\.yml/, 'one that asked for a login gets the file' );
    like( $login, qr/gh[ ]auth[ ]setup-git/,             'and git is told to ask gh for the credential' );

    # The token is in hosts.yml, which is 0600.  On a command line it would be
    # in the process table for every account on the guest to read.
    unlike( $login, qr/GH_TOKEN=/, 'the token is not passed on a command line' );
    unlike( $login, qr/ghp_x/,     'and the fragment does not hold it at all' );

    # The home of the account is asked for rather than assumed: a service user
    # lives under install_dir and an administrator under /home.
    like( $login, qr/getent[ ]passwd[ ]'koan'/, 'the fragment asks where the account lives' );

    # Nothing about keys, host keys or signing: gh uses none of them, and the
    # git recipe owns all three.
    unlike( $login, qr/ssh-keyscan|gpg\.format|signingkey|id_git/, 'and it says nothing about ssh' );
};

subtest 'what the recipes that require it ask for' => sub {
    my %koan = Provisioner::Cookbook->load( 'koan', distro => 'ubuntu' )->required_recipes(%G);
    ok( ref $koan{github} eq 'CODE', 'koan requires github' );

    my %asked = $koan{github}->( %G, koan_email => 'k@test.test', github_user => 'bot', github_token => 'ghp_x', github_ssh_identity => 1 );
    is( $asked{account},      'koan', 'for the account the bot runs as' );
    is( $asked{github_user},  'bot',  'with the GitHub account of the bot' );
    is( $asked{git_protocol}, 'ssh',  'cloning over ssh, the bot having a key' );

    my %without = $koan{github}->( %G, koan_email => 'k@test.test', github_user => 'bot', github_token => 'ghp_x' );
    is( $without{git_protocol}, 'https', 'and over https for a bot with none' );

    my %admincode = Provisioner::Cookbook->load( 'admincode', distro => 'ubuntu' )->required_recipes(%G);
    ok( ref $admincode{github} eq 'CODE', 'admincode requires it too' );
    is_deeply( [ $admincode{github}->(%G) ], [], 'and configures nothing: an administrator logs in themselves' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
