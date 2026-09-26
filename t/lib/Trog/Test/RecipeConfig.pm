package Trog::Test::RecipeConfig;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

Trog::Test::RecipeConfig - the least configuration that each recipe takes, for
the tests that render or generate every recipe

=head1 SYNOPSIS

    use Trog::Test::RecipeConfig();
    my %required = Trog::Test::RecipeConfig::required_config($dir);
    $recipe->render( %globals, %{ $required{mariadb} // {} } );

=head1 DESCRIPTION

A recipe that has a required field with no default cannot render without a
value for it.  F<t/recipes.t> renders every recipe, and
L<Trog::Test::RemoteTests> generates the domain of every recipe.  Both take the
values from here, so that a field that a recipe comes to require is added in
one place.

=head1 FUNCTIONS

=head2 %required = required_config($dir)

Returns a configuration for each recipe that needs one, keyed by the name of the
recipe.  A recipe that is not in it renders with no configuration of its own.

C<$dir> is a directory of the test.  Paths in the configuration are under it:

=over

=item F<$dir/data>

C<data_source> of the backup recipes.  They read their key from
F<$dir/data/$domain/backup.rsa>, so a test that renders them makes that key.

=item F<$dir/dotfiles>

C<skel> of adminconfig.

=back

C<modules> names the recipes that are on the guest beside the recipe.  A test
that renders the recipe hands it to the template as C<modules>, and a test that
generates the recipe's domain puts those recipes in the domain beside it, each
with the configuration that it has here.  Each call builds the configuration
anew, so a test can change what it gets.

=cut

sub required_config {
    my ($dir) = @_;

    return (

        # A mirror of no release, and a shipper with nowhere to ship.
        aptmirror  => { releases => ['noble'] },
        logshipper => { host     => 'logs.test.test' },

        # Full releases on purpose.  The archives they come from publish one
        # artifact per release, so a series like 7.1 or 11.4 is a 404 that the
        # recipe cannot do anything useful with.
        imagemagick => { version => '7.1.1-47' },
        mariadb     => {
            root_pw  => 's3cr3t',
            dumpfile => 'dump.sql',
            version  => '11.4.4',
        },
        gogs => { version => '0.13.0', admin_password => 's3cr3t' },

        # A password is not a thing a schema can default, and grubconf refuses
        # to render nothing.
        grafana       => { admin_password => 's3cr3t' },
        grafanasyslog => { modules        => ['grafana'] },
        grubconf      => { grub_vars      => { GRUB_TIMEOUT => '5', GRUB_CMDLINE_LINUX => 'net.ifnames=0' } },
        ldap          => { admin_password => 's3cr3t' },

        tpsgi           => { routers         => ['app.psgi'] },
        plexmediaserver => { plex_login_name => 'plexuser',      admin_mail => 'admin@test.test' },
        openvpnclient   => { server          => 'vpn.test.test', cert_dir   => '/opt/domains/test.test.test/vpn' },
        adminconfig     => { skel            => "$dir/dotfiles" },
        admincode       => {
            repos_from => [],
            basedir    => 'Code',
        },
        nginxproxy => {
            vhosts => {
                8080 => {
                    proxy_uri  => 'run/app.sock',
                    static_dir => 'www/static',
                },
            },
        },
        letsencrypt => {},
        pdns        => { api_key => 'test-api-key' },
        registrar   => { type    => 'easydns', user => 'somebody', key => 'a-token' },
        matrix      => {
            server_name    => 'test.test.test',
            admin_password => 's3cr3t',
            smtp_host      => 'mail.test.test',
            smtp_user      => 'notify@test.test',
            smtp_pass      => 'smtp-pass',
            smtp_from      => 'notify@test.test',
            modules        => ['nginxproxy'],
        },
        roundcube => {
            version => '1.6.0',
            modules => ['nginxproxy'],
        },
        github => {
            github_user  => 'test-bot',
            github_token => 'ghp_fakefakefake',
            git_protocol => 'ssh',
        },
        git => {
            accounts => {
                test => {
                    hosts        => ['github.com'],
                    ssh_identity => 1,
                    user_name    => 'test-bot',
                    user_email   => 'test-bot@test.test',
                },
            },
        },
        koan => {
            user               => 'koan',
            koan_email         => 'koan@test.test',
            messaging_provider => 'telegram',
            telegram_token     => 'fake-token',
            telegram_chat_id   => 12345,
            cli_provider       => 'local',
            github_user        => 'test-bot',
            github_token       => 'ghp_fakefakefake',
        },
        backupdestination => {
            base_dir    => '/opt/backups',
            hosts       => ['backup.host'],
            targets     => ['etc'],
            key_file    => 'backup.rsa',
            data_source => "$dir/data",
        },
        backup => {
            modules     => [],
            targets     => { etc => '/etc' },
            key_file    => 'backup.rsa',
            data_source => "$dir/data",
        },
        postgres => { dumps => [], version => 16 },
        sssd     => {
            ldap_uri => 'ldaps://ldap.test.test.test',
            base_dn  => 'dc=test,dc=test',
        },
    );
}

1;
