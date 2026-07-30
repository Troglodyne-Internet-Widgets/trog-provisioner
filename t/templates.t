#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);

my $template_dir = "$FindBin::Bin/../templates";

# Global vars bin/new_config injects into every template render.
my %G = (
    domain                     => 'test.example.com',
    subdomain                  => 'test',
    tld                        => 'example.com',
    install_dir                => '/opt/domains',
    data_source                => '/opt/data',
    script_dir                 => '/root/bin',
    user                       => 'www-data',
    admin_user                 => 'admin',
    admin_email                => 'admin@example.com',
    main_ip                    => '192.168.1.100',
    tld_ip                     => '192.168.1.1',
    hv_ip                      => '192.168.122.1',
    hv_ssh_port                => 22,
    transfer_user              => 'transfer',
    provisioner_dir            => "$FindBin::Bin/..",
    aliases                    => { test => ['www.test', 'mail.test'] },
    full_aliases               => ['www.test.example.com'],
    modules                    => [],
    ipmap                      => { test => '192.168.1.100' },
    nameservers                => {},
    packager_invocation        => 'apt-get install -y',
    packager_up_invocation     => 'apt-get upgrade -y',
    packager_remove_invocation => 'apt-get remove -y',
    local_dns_access_token     => '',
);

my %PROV = (
    target_packager => 'deb',
    template_dirs   => [$template_dir],
);

# Test that a recipe renders without error given %G merged with $extra.
sub renders_ok {
    my ( $name, $extra, $desc ) = @_;
    $desc //= $name;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    subtest $desc => sub {
        plan tests => 3;
        use_ok("Provisioner::Recipe::$name");
        my $r = eval { "Provisioner::Recipe::$name"->new(%PROV) };
        is( $@, '', "$name->new() succeeds" );
        SKIP: {
            skip "new() failed, skipping render", 1 unless $r;
            my $out = eval { $r->render( %G, %$extra ) };
            is( $@, '', "$name->render() succeeds" );
        }
    };
}

# Test that a recipe dies when a required field is absent.
# $extra should include all fields needed EXCEPT $field.
# We explicitly pass $field => undef to shadow any default in %G.
sub rejects_missing {
    my ( $name, $extra, $field, $desc ) = @_;
    $desc //= "$name rejects missing $field";
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    subtest $desc => sub {
        plan tests => 1;
        my $r = "Provisioner::Recipe::$name"->new(%PROV);
        eval { $r->render( %G, %$extra, $field => undef ) };
        ok( $@, "render() dies without $field" );
    };
}

# ----------------------------------------------------------------
# Recipes with no required configuration
# ----------------------------------------------------------------
renders_ok( 'nosnap',         {} );
renders_ok( 'nostubresolver', {} );
renders_ok( 'autoupdate',     {} );
renders_ok( 'grubconf',       {} );
renders_ok( 'auditd',         {} );
renders_ok( 'fail2ban',       {} );
renders_ok( 'ntp',            {}, 'ntp with defaults' );
renders_ok( 'ufw',            {}, 'ufw with no extra rules' );
renders_ok( 'cron',           {}, 'cron with no user scripts' );
renders_ok( 'mounts',         {}, 'mounts with no disks' );

# ----------------------------------------------------------------
# Recipes with required config
# ----------------------------------------------------------------
renders_ok( 'data', { from => '/opt/data', to => '/opt/domains' } );
renders_ok( 'perl', {} );    # user already in %G

renders_ok( 'imagemagick', { version => '7.1.0' } );
renders_ok( 'mariadb', {
    root_pw  => 's3cr3t',
    dumpfile => 'dump.sql',
    version  => '10.11',
} );
renders_ok( 'tpsgi', { routers => ['app.psgi'] } );
renders_ok( 'tcms',  { tcms_dir => 'tcms' } );
renders_ok( 'adminconfig', { skel => '/opt/dotfiles' } );
renders_ok( 'admincode', {
    repos_from => [],
    basedir    => 'Code',
} );
subtest 'backupdestination' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    system( 'ssh-keygen', '-t', 'rsa', '-b', '2048', '-f', "$tmp/key.rsa", '-N', '', '-q' );
    SKIP: {
        skip 'ssh-keygen unavailable or failed', 3 unless -f "$tmp/key.rsa";
        my $ddir = "$tmp/test.example.com";
        mkdir $ddir;
        system( 'cp', "$tmp/key.rsa", "$ddir/key.rsa" );

        use_ok('Provisioner::Recipe::backupdestination');
        my $r = Provisioner::Recipe::backupdestination->new(%PROV);
        my $out = eval {
            $r->render( %G,
                base_dir    => '/opt/backups',
                hosts       => ['backup.host'],
                targets     => ['etc'],
                key_file    => 'key.rsa',
                data_source => $tmp,
            )
        };
        is( $@, '', 'backupdestination->render() succeeds' );
        ok( length( $out // '' ) > 0, 'backupdestination->render() produces output' ) unless $@;
    }
};
renders_ok( 'nginxproxy', {
    proxy_uri  => 'run/app.sock',
    static_dir => 'www/static',
} );

# mail — all fields optional
renders_ok( 'mail', {}, 'mail with no names or forwarders' );
renders_ok( 'mail', {
    ipv6 => 0,
}, 'mail with ipv6 disabled' );

# letsencrypt — no prefer_local_dns → registrar hash required
renders_ok( 'letsencrypt', {
    registrar => { type => 'route53', user => 'foo', key => 'bar' },
} );

renders_ok( 'pdns', { api_key => 'test-api-key' } );

# Recipes that require 'nginxproxy' in modules list
renders_ok( 'matrix', {
    server_name    => 'test.example.com',
    admin_password => 's3cr3t',
    smtp_host      => 'mail.example.com',
    smtp_user      => 'notify@example.com',
    smtp_pass      => 'smtp-pass',
    smtp_domain    => 'example.com',
    modules        => ['nginxproxy'],
}, 'matrix with minimal config' );

renders_ok( 'roundcube', {
    version => '1.6.0',
    modules => ['nginxproxy'],
} );

# koan — complex but pure-Perl validate
renders_ok( 'koan', {
    user               => 'koan',
    koan_email         => 'koan@example.com',
    messaging_provider => 'telegram',
    telegram_token     => 'fake-token',
    telegram_chat_id   => 12345,
    cli_provider       => 'local',
    github_user        => 'test-bot',
    github_token       => 'ghp_fakefakefake',
}, 'koan recipe' );

# ----------------------------------------------------------------
# Backup recipe — needs a real SSH key on disk
# ----------------------------------------------------------------
subtest 'backup recipe' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    system( 'ssh-keygen', '-t', 'rsa', '-b', '2048', '-f', "$tmp/key.rsa", '-N', '', '-q' );

    SKIP: {
        skip 'ssh-keygen unavailable or failed', 3 unless -f "$tmp/key.rsa";

        my $domain_dir = "$tmp/test.example.com";
        mkdir $domain_dir or die "mkdir $domain_dir: $!";
        system( 'cp', "$tmp/key.rsa", "$domain_dir/key.rsa" );

        use_ok('Provisioner::Recipe::backup');
        my $r = Provisioner::Recipe::backup->new(%PROV);
        my $out = eval {
            $r->render(
                %G,
                modules     => [],
                targets     => { etc => '/etc' },
                key_file    => 'key.rsa',
                data_source => $tmp,
            )
        };
        is( $@, '', 'backup->render() succeeds with valid key' );
        ok( length( $out // '' ) > 0, 'backup->render() produces output' )
            unless $@;
    }
};

# ----------------------------------------------------------------
# Validate: required fields cause die
# ----------------------------------------------------------------
rejects_missing( 'mariadb', { dumpfile => 'd.sql', version => '10' }, 'root_pw' );
rejects_missing( 'mariadb', { root_pw => 'x', version => '10'     }, 'dumpfile' );
rejects_missing( 'mariadb', { root_pw => 'x', dumpfile => 'd.sql' }, 'version'  );

rejects_missing( 'nginxproxy', { static_dir => 'www/static' }, 'proxy_uri' );
rejects_missing( 'nginxproxy', { proxy_uri  => 'run/app.sock' }, 'static_dir' );

rejects_missing( 'adminconfig', {},                              'skel'    );
rejects_missing( 'tcms',        {},                              'tcms_dir' );
rejects_missing( 'imagemagick', {},                              'version'  );
rejects_missing( 'pdns',        {},                              'api_key'  );

rejects_missing( 'koan', {
    koan_email         => 'k@example.com',
    messaging_provider => 'telegram',
    telegram_token     => 'tok',
    telegram_chat_id   => 1,
    cli_provider       => 'local',
    github_user        => 'bot',
    github_token       => 'ghp_x',
}, 'user' );

rejects_missing( 'matrix', {
    server_name => 'test.example.com',
    smtp_host   => 'mail.example.com',
    smtp_user   => 'n@example.com',
    smtp_pass   => 'p',
    smtp_domain => 'example.com',
    modules     => ['nginxproxy'],
}, 'admin_password', 'matrix rejects missing admin_password' );

# ----------------------------------------------------------------
# ntp: validate enforces server list constraints
# ----------------------------------------------------------------
subtest 'ntp rejects empty server list' => sub {
    plan tests => 1;
    my $r = Provisioner::Recipe::ntp->new(%PROV);
    eval { $r->render( %G, servers => [] ) };
    ok( $@, 'ntp dies with empty servers list' );
};

subtest 'ntp rejects non-array servers' => sub {
    plan tests => 1;
    my $r = Provisioner::Recipe::ntp->new(%PROV);
    eval { $r->render( %G, servers => 'not-an-array' ) };
    ok( $@, 'ntp dies when servers is not an ARRAY' );
};

# ----------------------------------------------------------------
# ufw: validate enforces port_forward structure
# ----------------------------------------------------------------
subtest 'ufw rejects malformed port_forwards' => sub {
    plan tests => 1;
    my $r = Provisioner::Recipe::ufw->new(%PROV);
    eval { $r->render( %G, port_forwards => [ { from => 80 } ] ) };
    ok( $@, 'ufw dies when port_forward entry missing to' );
};

done_testing();
