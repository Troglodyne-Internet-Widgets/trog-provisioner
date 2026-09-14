#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Provisioner-Recipe-claude.t - whose GitHub identity a guest's claude acts under

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use Cpanel::JSON::XS();

use FindBin::libs;

use Provisioner::Cookbook();

my %BASE = (
    domain      => 'bot.test.test',
    install_dir => '/opt/domains',
    admin_user  => 'doge',
    script_dir  => '/root/bin',
    main_ip     => '192.168.1.9',
    modules     => [qw{perl perllsp claude}],
);

sub recipe {
    return Provisioner::Cookbook->load( 'claude', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

# What a domain gets when it says `claude:` and nothing else, which is what
# every domain running this recipe said before the identity existed.
subtest 'a domain that names no bot keeps the guest it had' => sub {
    my $fragment = recipe()->render(%BASE);

    unlike( $fragment, qr/hosts\.yml/, 'no gh credential is installed' );
    unlike( $fragment, qr/git config/, 'and no commit identity is set' );
    like( $fragment, qr/settings\.json/, 'while the settings file still is' );
};

subtest 'a domain that names one hands it to gh and to git' => sub {
    my %opts     = ( %BASE, github_user => 'troglodyne-bot', github_token => 'ghp_NOTAREALTOKEN', git_email => 'bot@test.test' );
    my $fragment = recipe()->render(%opts);

    like( $fragment, qr{install -m 0600 .*claude\.gh-hosts\.yml .*/\.config/gh/hosts\.yml}, 'the credential is installed 0600' );
    like( $fragment, qr/user\.name 'troglodyne-bot'/,                                       'the commit name is the bot' );
    like( $fragment, qr/user\.email 'bot\@test\.test'/,                                     'and so is the address GitHub attributes by' );

    # HOME rather than runuser: see the fragment.  runuser would use the
    # account's passwd home, which is this directory only when the service user
    # is the admin -- so on any other domain the identity and the token would
    # land in two different homes.
    unlike( $fragment, qr/runuser .* git config/, 'the identity goes to the same home as the token' );
    like( $fragment, qr{HOME='/opt/domains/bot\.test\.test' git config}, 'which is the domain directory' );
};

subtest 'the credential file carries what gh reads' => sub {
    my %opts = ( %BASE, github_user => 'troglodyne-bot', github_token => 'ghp_NOTAREALTOKEN' );
    my $dir  = tempdir( CLEANUP => 1 );
    my $r    = Provisioner::Cookbook->load( 'claude', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    $r->generate_files( $dir, %opts );

    my $hosts = do { local ( @ARGV, $/ ) = "$dir/claude.gh-hosts.yml"; <> }
      // '';
    like( $hosts, qr/^\s*user:\s*troglodyne-bot$/m,           'the account gh acts as' );
    like( $hosts, qr/^\s*oauth_token:\s*ghp_NOTAREALTOKEN$/m, 'and the token it acts with' );
};

# git_name follows github_user, which a schema default cannot express because it
# reads another field.
subtest 'the commit name follows the account unless it is told otherwise' => sub {
    my %got = recipe()->validated( %BASE, github_user => 'troglodyne-bot' );
    is( $got{git_name}, 'troglodyne-bot', 'it defaults to the GitHub account' );

    my %named = recipe()->validated( %BASE, github_user => 'troglodyne-bot', git_name => 'Somebody Else' );
    is( $named{git_name}, 'Somebody Else', 'and a domain naming one keeps it' );
};

# The defect this recipe shipped with: an enabled plugin whose marketplace the
# same file never declared loads nothing, and says nothing about it.
subtest 'every plugin the settings enable comes from a marketplace it declares' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = Provisioner::Cookbook->load( 'claude', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    $r->generate_files( $dir, %BASE );

    my $text = do { local ( @ARGV, $/ ) = "$dir/claude.settings.json"; <> }
      // '';
    my $conf = eval { Cpanel::JSON::XS::decode_json($text) };
    ok( $conf, 'the settings render as valid JSON' ) or diag $text;
    return unless $conf;

    my %declared = map { $_ => 1 } keys %{ $conf->{extraKnownMarketplaces} // {} };
    my @orphans  = grep {
        my $at     = index( $_, '@' );
        my $market = $at >= 0 ? substr( $_, $at + 1 ) : q{};
        !length($market) || !$declared{$market}
    } keys %{ $conf->{enabledPlugins} // {} };

    is_deeply( \@orphans, [], 'no enabled plugin names a marketplace that is not there' )
      or diag 'declared: ' . join( ', ', sort keys %declared );
};

Test::NoWarnings::had_no_warnings();

done_testing();
