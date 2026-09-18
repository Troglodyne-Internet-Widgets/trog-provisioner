#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-koan.t - what the koan recipe accepts, refuses and fills in

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};

use FindBin::libs;

use Provisioner::Cookbook();

my $recipe = Provisioner::Cookbook->load( 'koan', distro => 'ubuntu' )->new(
    template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir    => '/nonexistent',
    distro        => 'ubuntu',
);

# What every case needs, and a CLI provider that needs no token of its own.
my %BASE = (
    user         => 'koan',
    koan_email   => 'koan@test.test',
    github_user  => 'bot',
    github_token => 'ghp_x',
    cli_provider => 'local',
);

my %TELEGRAM = (
    messaging_provider => 'telegram',
    telegram_token     => 'fake-token',
    telegram_chat_id   => 1,
);

my %MATRIX = (
    messaging_provider => 'matrix',
    matrix_homeserver  => 'https://matrix.test.test',
    matrix_user_id     => '@koan:test.test',
    matrix_room_id     => '!room:test.test',
    matrix_password    => 'hunter2',
);

sub validated {
    my (%opts) = @_;
    return $recipe->validate( %BASE, %opts );
}

# The messaging provider decides which credentials are needed, not the CLI one.
subtest 'each messaging provider needs its credentials' => sub {
    like( exception { validated( messaging_provider           => 'telegram' ) }, qr/telegram_token/,    'telegram without a token is refused' );
    like( exception { validated( messaging_provider           => 'slack' ) },    qr/slack_bot_token/,   'slack without a token is refused' );
    like( exception { validated( messaging_provider           => 'matrix' ) },   qr/matrix_homeserver/, 'matrix without a homeserver is refused' );
    like( exception { validated( %MATRIX, matrix_access_token => 'syt_x' ) },    qr/exactly\ one/,      'matrix with a token and a password is refused' );

    my %telegram = validated(%TELEGRAM);
    is( $telegram{messaging_provider}, 'telegram', 'telegram with its credentials is accepted' );
};

subtest 'matrix is end to end encrypted unless told otherwise' => sub {
    my %on = validated(%MATRIX);
    ok( $on{matrix_e2ee}, 'E2EE is on by default' );
    like( $on{matrix_pickle_key}, qr/\A[[:xdigit:]]{64}\z/, 'and a pickle key is minted for it' );

    my %off = validated( %MATRIX, matrix_e2ee => 0 );
    ok( !$off{matrix_e2ee},              'matrix_e2ee: 0 turns it off' );
    ok( !exists $off{matrix_pickle_key}, 'and no pickle key is minted' );

    my %token = %MATRIX;
    delete $token{matrix_password};
    like(
        exception { validated( %token, matrix_access_token => 'syt_x' ) },
        qr/matrix_device_id/,
        'a pre-minted token needs its device under the default E2EE'
    );
};

# The fragment clones a project only when it has a github_url.  Every template
# reads its path.
subtest 'a project needs a path, and not a github_url' => sub {
    my %opts = validated( %TELEGRAM, projects => { legacy => { path => '/opt/projects/legacy' } } );
    is( $opts{projects}{legacy}{path}, '/opt/projects/legacy', 'a project with only a path is accepted' );

    like( exception { validated( %TELEGRAM, projects => { app => { github_url => 'org/app' } } ) },  qr{/projects/app/path}, 'a project without a path is refused' );
    like( exception { validated( %TELEGRAM, projects => { app => { path       => 'relative' } } ) }, qr{/projects/app/path}, 'a relative path is refused' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
