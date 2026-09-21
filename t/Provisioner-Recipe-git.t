#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-git.t - the identity git pushes and signs with, and what
koan and admincode ask of it

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

sub recipe { return Provisioner::Cookbook->load( 'git', distro => 'ubuntu' )->new(%PROV) }

subtest 'a guest that was told nothing gets nothing' => sub {
    my %got = recipe()->validated(%G);
    is_deeply( $got{accounts}, {}, 'no account is configured that nobody named' );

    my $bare = recipe()->render(%G);
    unlike( $bare, qr/ssh-keyscan/, 'so the fragment scans nothing' );
    unlike( $bare, qr/id_git/,      'places no key' );
    unlike( $bare, qr/gpg\.format/, 'and configures no signing' );
};

# The host keys are the half a forwarded key needs too: without them the first
# push waits on a prompt that nothing answers, which reads as a hang.
subtest 'host keys without a key of our own' => sub {
    my $said = recipe()->render( %G, accounts => { someadmin => { hosts => [ 'github.com', 'gitea.test' ] } } );

    like( $said, qr/ssh-keyscan[^\n]*'github\.com'/, 'each host is keyscanned' );
    like( $said, qr/ssh-keyscan[^\n]*'gitea\.test'/, 'including the second' );

    unlike( $said, qr/id_git/,      'and still no key' );
    unlike( $said, qr/gpg\.format/, 'nor signing, which needs one' );

    is_deeply( { recipe()->guest_secrets( '/opt/domains', 'bot.test.test', accounts => { someadmin => { hosts => ['github.com'] } } ) }, {}, 'nothing is taken from the store either' );
};

subtest 'a key with nobody to attribute it to is refused' => sub {
    my $nameless = exception { recipe()->validated( %G, accounts => { koan => { ssh_identity => 1, hosts => ['github.com'] } } ) };
    like( $nameless, qr/no[ ]user_email/, 'signing with no address is refused' );
    like( $nameless, qr/koan[ ]account/,  'and the refusal names the account, there being more than one' );

    # A key for a forge nobody named cannot push anywhere, and ssh would never
    # offer it: the config stanza it goes in names hosts.
    like(
        exception { recipe()->validated( %G, accounts => { koan => { ssh_identity => 1, user_email => 'bot@test.test' } } ) },
        qr/no[ ]hosts/,
        'and a key for no forge at all is refused'
    );
};

subtest 'the key, and what is configured with it' => sub {
    my %opts = ( %G, accounts => { koan => { ssh_identity => 1, hosts => ['github.com'], user_name => 'bot', user_email => 'bot@test.test' } } );

    my %placed = recipe()->guest_secrets( '/opt/domains', 'bot.test.test', %opts );
    is_deeply( [ keys %placed ], ['/opt/domains/bot.test.test/.ssh/id_git-koan'], 'the key is placed under the domain directory' );
    is( $placed{'/opt/domains/bot.test.test/.ssh/id_git-koan'}{ref}, 'secret:git/bot.test.test-koan-ssh/password', 'from the store, keyed on the domain and the account' );

    my $said = recipe()->render(%opts);
    like( $said, qr/ssh-keyscan[^\n]*'github\.com'/,   'the fragment trusts the forge' );
    like( $said, qr/IdentityFile[^\n]*\.ssh\/id_git/,  'points ssh at the key' );
    like( $said, qr/user\.email[ ]*'bot\@test\.test'/, 'says who the commits are from' );
    like( $said, qr/gpg\.format\s+ssh/,                'signs in the ssh format' );
    like( $said, qr/allowed_signers/,                  'and writes what verifies a signature on the guest' );

    # The home of the account is asked for rather than assumed: a service user
    # lives under install_dir and an administrator under /home.
    like( $said, qr/getent[ ]passwd[ ]'koan'/, 'and it asks where the account lives' );
};

subtest 'an identity without a key is just an identity' => sub {
    my $said = recipe()->render( %G, accounts => { someadmin => { user_name => 'somebody', user_email => 'somebody@test.test' } } );

    like( $said, qr/user\.email[ ]*'somebody\@test\.test'/, 'the author is configured' );
    unlike( $said, qr/gpg\.format/, 'and nothing is signed, there being no key to sign with' );
};

subtest 'what the recipes that require it ask for' => sub {
    my %koan = Provisioner::Cookbook->load( 'koan', distro => 'ubuntu' )->required_recipes(%G);
    ok( ref $koan{git} eq 'CODE', 'koan requires git' );

    my %asked = $koan{git}->( %G, koan_email => 'k@test.test', github_user => 'bot', github_ssh_identity => 1 );
    my $bot   = $asked{accounts}{koan};
    ok( $bot, 'for the account the bot runs as' );
    is( $bot->{ssh_identity}, 1,             'with the key it asked for' );
    is( $bot->{user_email},   'k@test.test', 'the address its commits are from' );
    is( $bot->{user_name},    'bot',         'the name on them' );
    is_deeply( $bot->{hosts}, ['github.com'], 'and the forge it pushes to' );

    my %quiet = $koan{git}->( %G, koan_email => 'k@test.test', github_user => 'bot' );
    is( $quiet{accounts}{koan}{ssh_identity}, 0, 'a bot that asked for no key gets none' );

    # An administrator forwards their own key.  The host keys are still wanted:
    # scripts/repos_for falls back to an ssh_url, and that push meets the same
    # prompt as any other.
    my %admincode = Provisioner::Cookbook->load( 'admincode', distro => 'ubuntu' )->required_recipes(%G);
    ok( ref $admincode{git} eq 'CODE', 'admincode requires it too' );

    my %wanted = $admincode{git}->( %G, repos_from => [ { api_url => 'https://gitea.test/api/v1/' }, { api_url => 'https://git.test/api/v1/' } ] );
    ok( $wanted{accounts}{someadmin}, 'for the administrator' );
    is_deeply( [ sort @{ $wanted{accounts}{someadmin}{hosts} } ], [qw{git.test gitea.test}], 'for the host keys of each forge it clones from' );
    ok( !$wanted{accounts}{someadmin}{ssh_identity}, 'and with no key: the operator forwards one' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
