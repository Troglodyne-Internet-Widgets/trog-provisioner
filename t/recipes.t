#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use FindBin::libs;

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp qw(tempdir);
use File::Find();

my $template_dir = "$FindBin::Bin/../templates";

# Global vars bin/new_config injects into every template render.
my %G = (
    domain                     => 'test.test.test',
    subdomain                  => 'test',
    tld                        => 'test.test',
    install_dir                => '/opt/domains',
    data_source                => '/opt/data',
    script_dir                 => '/root/bin',
    user                       => 'www-data',
    admin_user                 => 'admin',
    admin_email                => 'admin@test.test',
    main_ip                    => '192.168.1.100',
    tld_ip                     => '192.168.1.1',
    hv_ip                      => '192.168.122.1',
    hv_ssh_port                => 22,
    transfer_user              => 'transfer',
    provisioner_dir            => "$FindBin::Bin/..",
    aliases                    => { test => ['www.test', 'mail.test'] },
    full_aliases               => ['www.test.test.test'],
    modules                    => [],
    ipmap                      => { test => '192.168.1.100' },
    nameservers                => {},
    packager_invocation        => 'apt-get install -y',
    packager_up_invocation     => 'apt-get upgrade -y',
    packager_remove_invocation => 'apt-get remove -y',
    local_dns_access_token     => '',
    users                      => [
        { name => 'admin', gecos => 'Admin User', shell => '/bin/bash' },
        { name => 'alice', gecos => 'Alice Smith', shell => '/bin/bash' },
    ],
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
        use_ok("Provisioner::Recipe::$name");
        my $r;
        my $res = exception { $r = "Provisioner::Recipe::$name"->new(%PROV) };
        is( $res, undef, "$name->new() succeeds" );
        # We may or may not have global/domain specific templates, but we need at least one.
        my $has_template;
        if (-f "$template_dir/$name.tt") {
            $res = exception { $r->render( %G, %$extra ) };
            is( $@, '', "$name->render() succeeds" );
            $has_template++;
        }
        if (-f "$template_dir/$name.global.tt") {
            $res = exception { $r->render_global( %G, %$extra ) };
            is( $@, '', "$name->render_global() succeeds" );
            $has_template++;
        }
        ok($has_template, "Has either a global or domain specific template");
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
        my $r = "Provisioner::Recipe::$name"->new(%PROV);
        eval { $r->render( %G, %$extra, $field => undef ) };
        ok( $@, "render() dies without $field" );
    };
}

# Needed by backup recipes
my $tmp = tempdir( CLEANUP => 1 );
my $ddir = "$tmp/test.test.test";
mkdir $ddir;
system( 'ssh-keygen', '-t', 'rsa', '-b', '2048', '-f', "$ddir/key.rsa", '-N', '', '-q' );

# Build list of known modules with required input data
my %required_config = (
    data => { from => '/opt/data', to => '/opt/domains' },
    imagemagick =>  { version => '7.1.0' },
    mariadb => {
        root_pw  => 's3cr3t',
        dumpfile => 'dump.sql',
        version  => '10.11',
    },
    tpsgi => { routers => ['app.psgi'] },
    tcms =>  { tcms_dir => 'tcms' },
    adminconfig => { skel => '/opt/dotfiles' },
    admincode => {
        repos_from => [],
        basedir    => 'Code',
    },
    nginxproxy => {
        proxy_uri  => 'run/app.sock',
        static_dir => 'www/static',
    },
    letsencrypt => {
        registrar => { type => 'route53', user => 'foo', key => 'bar' },
    },
    pdns => { api_key => 'test-api-key' },
    matrix => {
        server_name    => 'test.test.test',
        admin_password => 's3cr3t',
        smtp_host      => 'mail.test.test',
        smtp_user      => 'notify@test.test',
        smtp_pass      => 'smtp-pass',
        smtp_domain    => 'test.test',
        modules        => ['nginxproxy'],
    },
    roundcube => {
        version => '1.6.0',
        modules => ['nginxproxy'],
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
        key_file    => 'key.rsa',
        data_source => $tmp,
    },
    backup => {
        modules     => [],
        targets     => { etc => '/etc' },
        key_file    => 'key.rsa',
        data_source => $tmp,
    },
    ldap => {
        admin_password => 's3cr3t',
    },
    sssd => {
        ldap_uri => 'ldaps://ldap.test.test.test',
        base_dn  => 'dc=test,dc=test',
    },
);

# test everything available.
my @available;
File::Find::find( {
    wanted => sub {
        my $object = $_;
        return unless (-f $object && $object =~ m/\.pm$/);
        my ($name) = $object =~ m/(.+)\.pm$/;
        push(@available, $name);
    },
},
"lib/Provisioner/Recipe/");

#
# Crank dat minimum viable case
#
foreach my $recipe (@available) {
    my $input = {};
    $input = $required_config{$recipe} if exists $required_config{$recipe};
    renders_ok( $recipe, $input, "$recipe with minimum viable input" );
}

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
    koan_email         => 'k@test.test',
    messaging_provider => 'telegram',
    telegram_token     => 'tok',
    telegram_chat_id   => 1,
    cli_provider       => 'local',
    github_user        => 'bot',
    github_token       => 'ghp_x',
}, 'user' );

rejects_missing( 'matrix', {
    server_name => 'test.test.test',
    smtp_host   => 'mail.test.test',
    smtp_user   => 'n@test.test',
    smtp_pass   => 'p',
    smtp_domain => 'test.test',
    modules     => ['nginxproxy'],
}, 'admin_password', 'matrix rejects missing admin_password' );

rejects_missing( 'ldap', {}, 'admin_password', 'ldap rejects missing admin_password' );
rejects_missing( 'sssd', { base_dn => 'dc=test,dc=test' }, 'ldap_uri', 'sssd rejects missing ldap_uri' );
rejects_missing( 'sssd', { ldap_uri => 'ldaps://ldap.example.com' }, 'base_dn', 'sssd rejects missing base_dn' );

# ----------------------------------------------------------------
# ntp: validate enforces server list constraints
# ----------------------------------------------------------------
subtest 'ntp rejects empty server list' => sub {
    my $r = Provisioner::Recipe::ntp->new(%PROV);
    my $res = exception { $r->render( %G, servers => [] ) };
    ok( $res, 'ntp dies with empty servers list' );
};

subtest 'ntp rejects non-array servers' => sub {
    my $r = Provisioner::Recipe::ntp->new(%PROV);
    my $res = exception { $r->render( %G, servers => 'not-an-array' ) };
    ok( $res, 'ntp dies when servers is not an ARRAY' );
};

# ----------------------------------------------------------------
# ufw: validate enforces port_forward structure
# ----------------------------------------------------------------
subtest 'ufw rejects malformed port_forwards' => sub {
    my $r = Provisioner::Recipe::ufw->new(%PROV);
    my $res = exception { $r->render( %G, port_forwards => [ { from => 80 } ] ) };
    ok( $res, 'ufw dies when port_forward entry missing to' );
};

#
# Render stuff with optional fields
#
renders_ok( 'mail', {
    ipv6 => 0,
}, 'mail with ipv6 disabled' );

# ----------------------------------------------------------------
# matrix: homeserver.yaml.tt includes redis block when redis is loaded
# ----------------------------------------------------------------
subtest 'matrix homeserver.yaml includes redis section when redis recipe is loaded' => sub {
    use_ok('Provisioner::Recipe::matrix');
    my $r = Provisioner::Recipe::matrix->new(%PROV);
    my %matrix_cfg = (
        server_name    => 'test.test.test',
        admin_password => 's3cr3t',
        smtp_host      => 'mail.test.test',
        smtp_user      => 'notify@test.test',
        smtp_pass      => 'smtp-pass',
        smtp_domain    => 'test.test',
        modules        => ['nginxproxy', 'redis'],
    );
    my $out;
    my $err = exception { $out = $r->render_file( 'files/matrix.homeserver.yaml.tt', %G, %matrix_cfg ) };
    is( $err, undef, 'render_file succeeds with redis in modules' );
    like( $out, qr/redis:/, 'homeserver.yaml contains redis block' );
    like( $out, qr/enabled:\s*true/, 'redis block has enabled: true' );
    like( $out, qr/host:\s*"127\.0\.0\.1"/, 'redis host defaults to 127.0.0.1' );
    like( $out, qr/port:\s*6379/, 'redis port defaults to 6379' );
    unlike( $out, qr/^\s+password: "/m, 'no redis password field when redis_password is not set' );
};

subtest 'matrix homeserver.yaml omits redis section when redis recipe is not loaded' => sub {
    use_ok('Provisioner::Recipe::matrix');
    my $r = Provisioner::Recipe::matrix->new(%PROV);
    my %matrix_cfg = (
        server_name    => 'test.test.test',
        admin_password => 's3cr3t',
        smtp_host      => 'mail.test.test',
        smtp_user      => 'notify@test.test',
        smtp_pass      => 'smtp-pass',
        smtp_domain    => 'test.test',
        modules        => ['nginxproxy'],
    );
    my $out;
    my $err = exception { $out = $r->render_file( 'files/matrix.homeserver.yaml.tt', %G, %matrix_cfg ) };
    is( $err, undef, 'render_file succeeds without redis in modules' );
    unlike( $out, qr/redis:/, 'homeserver.yaml has no redis block' );
};

subtest 'matrix homeserver.yaml includes redis password when redis_password is set' => sub {
    use_ok('Provisioner::Recipe::matrix');
    my $r = Provisioner::Recipe::matrix->new(%PROV);
    my %matrix_cfg = (
        server_name    => 'test.test.test',
        admin_password => 's3cr3t',
        smtp_host      => 'mail.test.test',
        smtp_user      => 'notify@test.test',
        smtp_pass      => 'smtp-pass',
        smtp_domain    => 'test.test',
        redis_password => 'supersecret',
        modules        => ['nginxproxy', 'redis'],
    );
    my $out;
    my $err = exception { $out = $r->render_file( 'files/matrix.homeserver.yaml.tt', %G, %matrix_cfg ) };
    is( $err, undef, 'render_file succeeds with redis_password set' );
    like( $out, qr/^\s+password:\s*"supersecret"/m, 'redis password appears in output' );
};

# TODO more stuff with optional fields - probably need to make Provisioner::Recipe insist you enumerate required/optional fields and validate automatically

Test::NoWarnings::had_no_warnings();
done_testing();
