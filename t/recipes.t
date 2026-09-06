#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/recipes.t - every recipe renders, and refuses what it should

=cut

# A -f or -x in here is asserting on a file this test just made, in a temporary
# directory nothing else can see.  There is no window for it to be wrong in, so
# the TOCTOU policies have nothing to catch.
## no critic (ValuesAndExpressions::ProhibitFiletest_f, ValuesAndExpressions::ProhibitFiletest_rwxRWX)

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw(tempdir);
use IPC::Run3();
use File::Find();
use File::Slurper();
use Text::Xslate();

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
    aliases                    => { test => [ 'www.test', 'mail.test' ] },
    full_aliases               => ['www.test.test.test'],
    modules                    => [],
    ipmap                      => { test => '192.168.1.100' },
    nameservers                => {},
    packager_invocation        => 'apt-get install -y',
    packager_up_invocation     => 'apt-get upgrade -y',
    packager_remove_invocation => 'apt-get remove -y',
    local_dns_access_token     => '',
    users                      => [
        { name => 'admin', gecos => 'Admin User',  shell => '/bin/bash' },
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
        if ( -f "$template_dir/$name.tt" ) {
            $res = exception { $r->render( %G, %$extra ) };
            is( $@, '', "$name->render() succeeds" );
            $has_template++;
        }
        if ( -f "$template_dir/$name.global.tt" ) {
            $res = exception { $r->render_global( %G, %$extra ) };
            is( $@, '', "$name->render_global() succeeds" );
            $has_template++;
        }
        ok( $has_template, "Has either a global or domain specific template" );
    };
}

# Test that a recipe dies when a required field is absent.
# $extra should include all fields needed EXCEPT $field.
# The field is passed as undef on purpose, to shadow any default in %G.
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
my $tmp  = tempdir( CLEANUP => 1 );
my $ddir = "$tmp/test.test.test";
mkdir $ddir;
IPC::Run3::run3( [ qw{ssh-keygen -t rsa -b 2048 -f}, "$ddir/key.rsa", qw{-N}, '', qw{-q} ], \undef, \undef, undef );

# Build list of known modules with required input data
my %required_config = (
    data        => { from    => '/opt/data', to => '/opt/domains' },
    imagemagick => { version => '7.1.0' },
    mariadb     => {
        root_pw  => 's3cr3t',
        dumpfile => 'dump.sql',
        version  => '10.11',
    },
    tpsgi       => { routers  => ['app.psgi'] },
    tcms        => { tcms_dir => 'tcms' },
    adminconfig => { skel     => '/opt/dotfiles' },
    admincode   => {
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
    letsencrypt => {
        registrar => { type => 'route53', user => 'foo', key => 'bar' },
    },
    pdns   => { api_key => 'test-api-key' },
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
File::Find::find(
    {
        wanted => sub {
            my $object = $_;
            return unless ( -f $object && $object =~ m/\.pm$/ );
            my ($name) = $object =~ m/(.+)\.pm$/;
            push( @available, $name );
        },
    },
    "lib/Provisioner/Recipe/"
);

#
# Crank dat minimum viable case
#
foreach my $recipe (@available) {
    my $input = {};
    $input = $required_config{$recipe} if exists $required_config{$recipe};
    renders_ok( $recipe, $input, "$recipe with minimum viable input" );
}

# The guest rsyncs its payload off the hypervisor, so every one of these has to
# name it.  When the host came out empty the recipe still rendered, and still
# looked plausible -- 'doge@:/opt/data/...' -- and only failed on the guest,
# hours later, at the point where it had already been told the build succeeded.
subtest 'every rsync off the hypervisor names it' => sub {
    my %seen;
    foreach my $recipe (qw{data adminconfig makefile openvpnclient}) {
        foreach my $tt ( "$template_dir/$recipe.tt", "$template_dir/$recipe.global.tt" ) {
            next unless -f $tt;

            # Configured the way new_config configures it, bridge and all;
            # a bare Xslate cannot render the ones using TT2 vmethods.
            my $xslate = Text::Xslate->new(
                path     => [$template_dir],
                syntax   => 'TTerse',
                module   => [qw{Text::Xslate::Bridge::TT2}],
                function => { tabinate => Text::Xslate::html_builder( sub { $_[0] } ) },
            );
            my $out = $xslate->render_string( File::Slurper::read_text($tt), { %G, %{ $required_config{$recipe} // {} } } );
            next unless index( $out, 'rsync' ) >= 0;
            $seen{$recipe}++;
            unlike( $out, qr/\@:/, "$recipe: no empty host between the user and the path" );
            like( $out, qr/\@\Q$G{hv_ip}\E:/, "$recipe: rsyncs from $G{hv_ip}" );
        }
    }
    ok( scalar keys %seen, 'and there were rsyncing recipes to check' );
};

# ----------------------------------------------------------------
# Validate: required fields cause die
# ----------------------------------------------------------------
rejects_missing( 'mariadb', { dumpfile => 'd.sql', version  => '10' },    'root_pw' );
rejects_missing( 'mariadb', { root_pw  => 'x',     version  => '10' },    'dumpfile' );
rejects_missing( 'mariadb', { root_pw  => 'x',     dumpfile => 'd.sql' }, 'version' );

rejects_missing( 'adminconfig', {}, 'skel' );
rejects_missing( 'imagemagick', {}, 'version' );
rejects_missing( 'pdns',        {}, 'api_key' );

rejects_missing(
    'koan',
    {
        koan_email         => 'k@test.test',
        messaging_provider => 'telegram',
        telegram_token     => 'tok',
        telegram_chat_id   => 1,
        cli_provider       => 'local',
        github_user        => 'bot',
        github_token       => 'ghp_x',
    },
    'user'
);

rejects_missing(
    'matrix',
    {
        server_name => 'test.test.test',
        smtp_host   => 'mail.test.test',
        smtp_user   => 'n@test.test',
        smtp_pass   => 'p',
        smtp_domain => 'test.test',
        modules     => ['nginxproxy'],
    },
    'admin_password',
    'matrix rejects missing admin_password'
);

rejects_missing( 'ldap', {}, 'admin_password', 'ldap rejects missing admin_password' );
rejects_missing( 'sssd', { base_dn  => 'dc=test,dc=test' },          'ldap_uri', 'sssd rejects missing ldap_uri' );
rejects_missing( 'sssd', { ldap_uri => 'ldaps://ldap.example.com' }, 'base_dn',  'sssd rejects missing base_dn' );

# ----------------------------------------------------------------
# ntp: validate enforces server list constraints
# ----------------------------------------------------------------
subtest 'ntp rejects empty server list' => sub {
    my $r   = 'Provisioner::Recipe::ntp'->new(%PROV);
    my $res = exception { $r->render( %G, servers => [] ) };
    ok( $res, 'ntp dies with empty servers list' );
};

subtest 'ntp rejects non-array servers' => sub {
    my $r   = 'Provisioner::Recipe::ntp'->new(%PROV);
    my $res = exception { $r->render( %G, servers => 'not-an-array' ) };
    ok( $res, 'ntp dies when servers is not an ARRAY' );
};

# ----------------------------------------------------------------
# ufw: validate enforces port_forward structure
# ----------------------------------------------------------------
subtest 'ufw rejects malformed port_forwards' => sub {
    my $r   = 'Provisioner::Recipe::ufw'->new(%PROV);
    my $res = exception { $r->render( %G, port_forwards => [ { from => 80 } ] ) };
    ok( $res, 'ufw dies when port_forward entry missing to' );
};

# ----------------------------------------------------------------
# ufw: two recipes listening on one port
# ----------------------------------------------------------------
subtest 'ufw settles rate limits by taking the higher, and nothing else' => sub {
    my $r = 'Provisioner::Recipe::ufw'->new(%PROV);

    # A limit says where traffic to a port stops being plausible, so the recipe
    # expecting the most legitimate traffic is the one that knows.  The lower
    # would let a quiet recipe throttle a busy one's users.
    my $merged = { rate_limits => { 443 => 500, 6379 => 512 } };
    $r->reconcile( $merged, { rate_limits => { 443 => 2000 } } );
    is( $merged->{rate_limits}{443}, 2000, 'the higher limit wins' );

    $r->reconcile( $merged, { rate_limits => { 443 => 100 } } );
    is( $merged->{rate_limits}{443}, 2000, 'and a lower one does not lower it' );

    is( $merged->{rate_limits}{6379}, 512, 'a port only one recipe named is left alone' );

    # Only rate limits.  Anything else two recipes disagree about here is a
    # misconfiguration somebody has to settle.
    like(
        exception { $r->reconcile( { port_forwards => 'a' }, { port_forwards => 'b' } ) },
        qr/different things from ufw/,
        'a field it has no rule for dies, named for the recipe to set it under'
    );
};

# ----------------------------------------------------------------
# cron: MAILFROM is a local part, and the templates append the domain
# ----------------------------------------------------------------
subtest 'cron addresses: a local part gets the domain, an address does not' => sub {
    my $d = $G{domain};

    # A fresh recipe per configuration, because that is what new_config builds:
    # one object per domain, rendered once with the options that domain merged.
    # validated() memoizes on the object to match, so two configurations through
    # one object would get the first one's answer twice.
    my $cron = sub { 'Provisioner::Recipe::cron'->new(%PROV) };

    is( exception { $cron->()->render( %G, from => 'cron' ) }, undef, 'a bare local part is accepted' );

    like(
        $cron->()->render_file( 'files/cron.root.tt', %G, from => 'cron' ),
        qr/^MAILFROM="cron\@\Q$d\E"$/m, 'and gets the domain appended'
    );

    # Appending to an address gives somebody@example.com@this.domain, which is
    # what the old template did to every value the old schema would accept.
    like(
        $cron->()->render_file( 'files/cron.root.tt', %G, from => 'someone@example.com' ),
        qr/^MAILFROM="someone\@example\.com"$/m, 'an address is left exactly as it stands'
    );
};

subtest 'cron MAILTO per script' => sub {
    my $r   = 'Provisioner::Recipe::cron'->new(%PROV);
    my $d   = $G{domain};
    my @out = split(
        "\n",
        $r->render_file(
            'files/cron.root.domain.tt', %G,
            root_scripts => [
                { interval => '0 0 * * *',   cmd => '/silent.pl' },
                { interval => '*/5 * * * *', cmd => '/addressed.pl', mailto => 'someone@example.com' },
                { interval => '*/7 * * * *', cmd => '/local.pl',     mailto => 'ops' },
                { interval => '*/9 * * * *', cmd => '/none.pl',      mailto => 'none' },
            ]
        )
    );

    # The MAILTO in force for a line is the last one before it.
    my %to;
    my $current = '';
    foreach my $line (@out) {
        $current = $1       if $line =~ m/^MAILTO="([^"]*)"$/;
        $to{$1}  = $current if $line =~ m{command (/\S+)};
    }

    is(
        $to{'/silent.pl'}, $G{admin_email},
        'a script that says nothing about mail has not been thought about, so the admin gets it'
    );
    is(
        $to{'/none.pl'}, '',
        q{and one that says 'none' does not want it, which cron spells as an empty MAILTO}
    );
    is( $to{'/addressed.pl'}, 'someone@example.com', 'an address is left alone' );
    is( $to{'/local.pl'},     "ops\@$d",             'a local part gets the domain' );
};

#
# Render stuff with optional fields
#
renders_ok(
    'mail',
    {
        ipv6 => 0,
    },
    'mail with ipv6 disabled'
);

# ----------------------------------------------------------------
# matrix: homeserver.yaml.tt includes redis block when redis is loaded
# ----------------------------------------------------------------
subtest 'matrix homeserver.yaml includes redis section when redis recipe is loaded' => sub {
    use_ok('Provisioner::Recipe::matrix');
    my $r          = 'Provisioner::Recipe::matrix'->new(%PROV);
    my %matrix_cfg = (
        server_name    => 'test.test.test',
        admin_password => 's3cr3t',
        smtp_host      => 'mail.test.test',
        smtp_user      => 'notify@test.test',
        smtp_pass      => 'smtp-pass',
        smtp_domain    => 'test.test',
        redis_host     => '127.0.0.1',
        redis_port     => 6379,
        modules        => [ 'nginxproxy', 'redis' ],
    );
    my $out;
    my $err = exception { $out = $r->render_file( 'files/matrix.homeserver.yaml.tt', %G, %matrix_cfg ) };
    is( $err, undef, 'render_file succeeds with redis in modules' );
    like( $out, qr/redis:/,                 'homeserver.yaml contains redis block' );
    like( $out, qr/enabled:\s*true/,        'redis block has enabled: true' );
    like( $out, qr/host:\s*"127\.0\.0\.1"/, 'redis host defaults to 127.0.0.1' );
    like( $out, qr/port:\s*6379/,           'redis port defaults to 6379' );
    unlike( $out, qr/^\s+password: "/m, 'no redis password field when redis_password is not set' );
};

subtest 'matrix homeserver.yaml omits redis section when redis recipe is not loaded' => sub {
    use_ok('Provisioner::Recipe::matrix');
    my $r          = 'Provisioner::Recipe::matrix'->new(%PROV);
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
    my $r          = 'Provisioner::Recipe::matrix'->new(%PROV);
    my %matrix_cfg = (
        server_name    => 'test.test.test',
        admin_password => 's3cr3t',
        smtp_host      => 'mail.test.test',
        smtp_user      => 'notify@test.test',
        smtp_pass      => 'smtp-pass',
        smtp_domain    => 'test.test',
        redis_password => 'supersecret',
        modules        => [ 'nginxproxy', 'redis' ],
    );
    my $out;
    my $err = exception { $out = $r->render_file( 'files/matrix.homeserver.yaml.tt', %G, %matrix_cfg ) };
    is( $err, undef, 'render_file succeeds with redis_password set' );
    like( $out, qr/^\s+password:\s*"supersecret"/m, 'redis password appears in output' );
};

# TODO more stuff with optional fields - probably need to make Provisioner::Recipe insist you enumerate required/optional fields and validate automatically

# Xslate lexes the inside of a directive, comments included, so an apostrophe in
# a [%# ... %] block opens a string that runs to whatever quote comes next.
# Everything between is swallowed, and what comes out is a shorter file, or an
# empty one, with no error anywhere -- a comment reading "every domain's
# aliases" emptied the whole nginx vhost.
subtest 'no template comment leaves a quote open' => sub {
    my @templates;
    File::Find::find(
        { no_chdir => 1, wanted => sub { push @templates, $File::Find::name if m/[.]tt\z/ } },
        $template_dir,
    );
    ok( scalar @templates, 'there are templates to check' );

    foreach my $tt ( sort @templates ) {
        my $body = File::Slurper::read_text($tt);
        ( my $name = $tt ) =~ s/^\Q$template_dir\E\///;

        # Every [%# ... %] block, which may span lines.
        while ( $body =~ m/(\[%#.*?%\])/gs ) {
            my $comment = $1;

            # A comment ends at the first %] there is, so a directive written
            # inside one closes it early and the rest of the prose becomes part
            # of the template.  A comment saying `[% user %]` in passing put
            # ", not by a hardcoded koan.  The account is whatever the" into a
            # Makefile, where make read it as a command.
            ok(
                index( $comment, '[%', 2 ) < 0,
                "$name: no directive inside a comment"
            ) or diag $comment;
            foreach my $quote ( q{'}, q{"} ) {
                my $count = () = $comment =~ m/\Q$quote\E/g;
                ok( $count % 2 == 0, "$name: a comment closes every $quote it opens" )
                  or diag $comment;
            }
        }
    }
};

# A guest test is a template that becomes a Perl script, and nothing checked it
# was one until it ran on a guest -- at the end of a provision, which is a slow
# way to find a syntax error.  Test::More also exits 255 when a script makes no
# assertions at all, so a test that renders to nothing fails the whole build for
# a recipe that was asked to do nothing.
subtest 'every guest test renders to a Perl script that says something' => sub {
    my $xslate = Text::Xslate->new(
        path     => [$template_dir],
        syntax   => 'TTerse',
        module   => [qw{Text::Xslate::Bridge::TT2}],
        function => { tabinate => Text::Xslate::html_builder( sub { $_[0] } ) },
    );

    # Enough of a configuration for any of them to render.  What matters is that
    # the result is Perl and has assertions in it, not what it would assert.
    my %vars = (
        %G,
        domain       => 'd.test',       install_dir => '/opt/domains',
        admin_user   => 'doge',         user        => 'svc',
        script_dir   => '/root/bin',    version     => '1.2.3-4',
        zone         => 'dc1',          buckets     => ['a'],
        channels     => ['x'],          disks       => [],
        fuse         => [],             gogs_admin  => 'git',
        key_file     => 'key.rsa',      pubkey      => 'ssh-rsa AAAA',
        admin_email  => 'a@b.test',     base_dn     => 'dc=d,dc=test',
        full_aliases => ['www.d.test'], modules     => ['perl'],
        vhosts       => {},             upstreams   => {},
        tcms_dir     => 'tCMS',         basedir     => 'code',
        port         => 636,            users       => [],
    );

    my $dir = tempdir( CLEANUP => 1 );
    my @tests;
    File::Find::find(
        { no_chdir => 1, wanted => sub { push @tests, $File::Find::name if m/[.]tt\z/ } },
        "$template_dir/tests",
    );
    ok( scalar @tests, 'there are guest tests to check' );

    foreach my $tt ( sort @tests ) {
        ( my $name = $tt ) =~ s{.*/}{};

        my $rendered = eval { $xslate->render( "tests/$name", \%vars ) };
        ok( defined $rendered, "$name renders" ) or do { diag $@; next };

        # It has to be Perl.
        my $file = "$dir/" . ( $name =~ s/[.]tt\z/.t/r );
        File::Slurper::write_text( $file, $rendered );

        my ( $out, $err ) = ( q{}, q{} );
        IPC::Run3::run3( [ $^X, '-c', $file ], \undef, \$out, \$err );
        is( $? >> 8, 0, "$name compiles" ) or diag $err;

        # And it has to assert something, or Test::More exits 255 on it.
        ok(
            $rendered =~ m/\b(?:ok|is|isnt|like|unlike|cmp_ok|is_deeply|pass|fail|plan|skip_all|BAIL_OUT)\b/,
            "$name makes at least one assertion or says why it is not"
        );
    }
};

# cron runs a job with /bin/sh, which is dash on Ubuntu, and dash reads &> as a
# background & followed by a redirection.  A cron line written with it runs
# detached, captures nothing, and reports success to cron the instant it starts
# -- which is how the nightly apt upgrade and the nightly backup both came to
# run unlogged and unwatched.
subtest 'no cron template redirects with &>' => sub {
    my @crons;
    File::Find::find(
        { no_chdir => 1, wanted => sub { push @crons, $File::Find::name if m/cron[^\/]*[.]tt\z/ } },
        $template_dir,
    );
    ok( scalar @crons, 'there are cron templates to check' );

    foreach my $tt ( sort @crons ) {
        ( my $name = $tt ) =~ s{^\Q$template_dir\E/}{};
        foreach my $line ( split m/\n/, File::Slurper::read_text($tt) ) {
            next if $line =~ m/^\s*#/;    # the comment explaining this rule
            unlike( $line, qr/&>>?/, "$name: no &> in a cron line" ) or diag $line;
        }
    }
};

subtest 'what a rebuild is not allowed to carry over' => sub {
    require Provisioner::Recipe;
    require Provisioner::Recipe::tcms;

    is_deeply( [ Provisioner::Recipe->remote_skip() ], [], 'a recipe salvages everything it names by default' );

    # tCMS's config directory comes down whole, and the key that makes a stolen
    # auth.db useless is in it when the install is not run under systemd.  That
    # key is supposed to die with its machine: carried over it would outlive the
    # machine it was made for, and in a backup beside the database it protects it
    # would not be protecting anything.
    my %files = Provisioner::Recipe::tcms->remote_files( '/opt/domains', 'test.test.test' );
    my ($config) = grep { m{/tCMS/config/$} } keys(%files);
    ok( $config, 'tCMS salvages its config directory' );

    my @skip = Provisioner::Recipe::tcms->remote_skip();
    ok( scalar(@skip),                                   'and says something in it must stay behind' );
    ok( ( grep { "${config}secrets.key" =~ $_ } @skip ), 'which is the vault key' );

    # And nothing else out of that directory, since the rest of it is the state
    # the salvage exists for.
    foreach my $keep (qw{auth.db main.cfg has_users}) {
        ok( !( grep { "$config$keep" =~ $_ } @skip ), "$keep still comes over" );
    }
};

# ----------------------------------------------------------------
# configd: the recipes for the software that has no conf.d
# ----------------------------------------------------------------
subtest 'the recipes covered by a configd language ask for it' => sub {

    # Naming the languages here rather than having configd know which recipes
    # exist: the recipe that configures the software is the one that knows which
    # file it is about to write into.
    my %want = (
        mail  => [qw{opendkim opendmarc postfix}],
        redis => ['redis'],
    );

    foreach my $recipe ( sort keys %want ) {
        my %required = "Provisioner::Recipe::$recipe"->new(%PROV)->required_recipes( %G, %{ $required_config{$recipe} // {} } );
        ok( $required{configd}, "$recipe pulls in configd" ) or next;

        my %args = $required{configd}->(%G);
        is_deeply( $args{languages}, $want{$recipe}, "and asks it for @{$want{$recipe}}" );
    }
};

subtest 'configd takes the union of what asked for it' => sub {
    my $r = 'Provisioner::Recipe::configd'->new(%PROV);

    # Which is how they arrive: Hash::Merge joins two dependants' arrays, so a
    # language two recipes both need is in the list twice.  Rendering `configd
    # adopt postfix` twice is harmless and looks like a bug in the makefile.
    my %opts = $r->validate( %G, languages => [qw{postfix redis postfix opendkim}] );
    is_deeply( $opts{languages}, [qw{opendkim postfix redis}], 'deduplicated and sorted' );

    # It becomes a module name and a shell argument, and it is the one thing
    # here that comes from configuration rather than from another recipe.
    like(
        exception { 'Provisioner::Recipe::configd'->new(%PROV)->validate( %G, languages => ['postfix; rm -rf /'] ) },
        qr/languages/,
        'and a language name that is not a name is refused'
    );
};

subtest 'the makefile fragment adopts every language it was given' => sub {
    my $out = 'Provisioner::Recipe::configd'->new(%PROV)->render( %G, languages => [qw{postfix redis}] );

    like( $out, qr{install_configd}, 'it installs Configd against the system perl' );

    foreach my $language (qw{postfix redis}) {

        # Once during the build, so the fragment directories exist and a bad
        # language name fails the build rather than the postrun.
        like( $out, qr{configd adopt --no-restart '$language'}, "$language is adopted without restarting anything" );

        # And once after it, when every recipe has written its fragments.
        like( $out, qr{queue_postrun_task /usr/bin/configd adopt '$language'}, "and adopted again once the makefile is done" );
    }
};

subtest 'mail writes fragments rather than editing the files' => sub {
    my $r   = 'Provisioner::Recipe::mail'->new(%PROV);
    my $out = $r->render(%G);

    # postconf sets a parameter and cannot add to one, which is the whole reason
    # a second domain used to take the first one's mail with it.
    unlike( $out, qr/^postconf /m, 'no postconf -e survives in the fragment' );
    like( $out, qr{main\.cf\.d/50-\Q$G{domain}\E},        'main.cf gets a fragment named for the domain' );
    like( $out, qr{opendmarc\.conf\.d/50-\Q$G{domain}\E}, 'and so does opendmarc.conf' );

    # Every one of these was a single file at a fixed path that the next domain
    # overwrote, taking the previous one's mail with it.
    foreach my $table (qw{virtual_maps virtual_aliases transport_maps sdd_relay_maps sender_login header_checks}) {
        like( $out, qr{/etc/postfix/domains/\Q$G{domain}\E/$table\b}, "$table is this domain's own file" );
    }
    unlike( $out, qr{/etc/postfix/virtual/maps\b}, 'nothing writes the shared virtual map any more' );
    unlike( $out, qr{recipient_access_pcre},       'and the recipient access table is gone entirely' );

    # Overwriting a file configd generates works until the next restart, and
    # then silently does not.
    unlike( $out, qr{mv \S* /etc/opendkim\.conf},  'nothing overwrites /etc/opendkim.conf' );
    unlike( $out, qr{mv \S* /etc/opendmarc\.conf}, 'nor /etc/opendmarc.conf' );

    my $global = $r->render_global(%G);
    like( $global, qr{main\.cf\.d/40-mail},       'the guest-wide half of main.cf is written once' );
    like( $global, qr{master\.cf\.d/40-mail},     'and so is master.cf' );
    like( $global, qr{opendkim\.conf\.d/40-mail}, 'and opendkim.conf, none of which is per domain' );
};

subtest 'the milters are named once, not once per domain' => sub {

    # smtpd_milters is a parameter configd joins across fragments.  Named in the
    # per-domain half, two domains would have postfix run opendkim twice and
    # sign every message twice over.
    my $r = 'Provisioner::Recipe::mail'->new(%PROV);
    unlike( $r->render_file( 'files/mail.postfix.main.tt', %G ), qr/^smtpd_milters/m, 'not in the domain fragment' );
    like( $r->render_file( 'files/mail.postfix.main.global.tt', %G ), qr/^smtpd_milters/m, 'in the guest-wide one' );
};

subtest 'master.cf fragment rows name the types the package ships' => sub {

    # configd keys a master.cf row on the service name and its type together, so
    # a row naming a type the package does not use is a second service rather
    # than an override -- and two queue managers share one queue.
    my $master = 'Provisioner::Recipe::mail'->new(%PROV)->render_file( 'files/mail.postfix.master.tt', %G );

    foreach my $service (qw{pickup qmgr}) {
        like( $master, qr/^$service\s+unix\s/m, "$service is unix-domain, as postfix has shipped it since 3.0" );
        unlike( $master, qr/^$service\s+fifo\s/m, "and not also a fifo" );
    }
};

subtest 'redis writes a fragment and keeps the packaged config underneath' => sub {
    my $r      = 'Provisioner::Recipe::redis'->new(%PROV);
    my $global = $r->render_global(%G);

    like( $global, qr{redis\.conf\.d/50-provisioner}, 'the configuration goes in as a fragment' );
    unlike( $global, qr{cp \S+ /etc/redis/redis\.conf}, 'and does not overwrite the generated file' );

    # An empty save is what turns RDB persistence off; adding snapshot points
    # without it only ever means more snapshots than the package asked for.
    my $off = 'Provisioner::Recipe::redis'->new(%PROV)->render_file( 'files/redis.conf.tt', %G, save => 0 );
    like( $off, qr/^save ""$/m, 'save: 0 clears every snapshot point named before it' );
    unlike( $off, qr/^save \d/m, 'and names none of its own' );
};

subtest 'the address classes do not overlap' => sub {
    my $r = 'Provisioner::Recipe::mail'->new(%PROV);

    # postfix's VIRTUAL_README: "NEVER list a virtual MAILBOX domain name as a
    # mydestination domain!"  www. and mail. were in both, which is what the
    # check_recipient_access table existed to paper over.
    my $domain = $r->render_file( 'files/mail.postfix.main.tt',        %G );
    my $guest  = $r->render_file( 'files/mail.postfix.main.global.tt', %G );

    is( ( $domain =~ m/^virtual_mailbox_domains = (.*)$/m )[0], $G{domain}, 'the domain is a virtual mailbox domain' );
    unlike( $domain, qr/^mydestination/m, 'and the per-domain half adds nothing to mydestination' );

    # The guest's hostname is the domain it hosts, so the postfix package's own
    # main.cf names that domain in mydestination and accumulation can only add
    # to it.  Without the reset, local delivery wins the tie and the domain's
    # mail stops reaching anybody's mailbox.
    like( $guest, qr/^mydestination =$/m,                         'the guest-wide half resets mydestination' );
    like( $guest, qr/^mydestination = \$myhostname, localhost$/m, 'before naming what is actually local' );

    # The check it used to make, postfix makes by itself.
    unlike( $guest, qr/^[^#]*check_recipient_access/m, 'no recipient access table in the restriction list' );
};

subtest 'an authenticated sender must own the address' => sub {
    my $r     = 'Provisioner::Recipe::mail'->new(%PROV);
    my $guest = $r->render_file( 'files/mail.postfix.main.global.tt', %G );

    my ($senders) = $guest =~ m/^smtpd_sender_restrictions = (.*)$/m;
    ok( $senders, 'there is a sender restriction list' ) or return;

    # A restriction list stops at the first permit, so behind
    # permit_sasl_authenticated the check would never run and one user could
    # send as another.
    my @order    = split( m/,\s*/, $senders );
    my ($check)  = grep { $order[$_] eq 'reject_authenticated_sender_login_mismatch' } 0 .. $#order;
    my ($permit) = grep { $order[$_] eq 'permit_sasl_authenticated' } 0 .. $#order;
    ok( defined $check,                      'which enforces sender ownership' );
    ok( defined $permit && $check < $permit, 'ahead of the permit that would otherwise end the list' );
};

subtest 'the sender login map covers every address a user sends from' => sub {

    # An address absent from it has no owner, and an authenticated client using
    # one is refused -- so a user this misses is mail that stops going out.
    my $r   = 'Provisioner::Recipe::mail'->new(%PROV);
    my $map = $r->render_file(
        'files/mail.sender_login.tt', %G,
        names        => { me => { gecos => 'Me', password => 'x' } },
        mail_aliases => [ { from => 'sales', to => 'me' }, { from => 'help', to => 'someone@elsewhere.test' } ],
    );

    like( $map, qr/^me\@\Q$G{domain}\E me\@\Q$G{domain}\E$/m,    'an account owns its own address' );
    like( $map, qr/^sales\@\Q$G{domain}\E me\@\Q$G{domain}\E$/m, 'an alias is owned by who it delivers to' );

    # Appending the domain to an address that already has one gives an owner
    # nobody can ever log in as.
    like( $map, qr/^help\@\Q$G{domain}\E someone\@elsewhere\.test$/m, 'and an alias out of the domain keeps its address' );
};

# ----------------------------------------------------------------
# tmpfs: /tmp on a tmpfs, at a size the operator picks
# ----------------------------------------------------------------
subtest 'tmpfs writes a unit systemd can see, and only enables it' => sub {
    my $out = 'Provisioner::Recipe::tmpfs'->new(%PROV)->render_global(%G);

    # Debian ships tmp.mount in /usr/share/systemd, which is how it ships it
    # off.  A unit systemd cannot see is one nothing can enable.
    like( $out, qr{/etc/systemd/system/tmp\.mount}, 'the unit goes where systemd looks' );

    # Enabled-but-not-mounted is not a state a running system stays in:
    # tmp.mount is WantedBy=local-fs.target, so the next restart of anything
    # re-pulls that target and mounts it.  Since it happens either way, it
    # happens here, where every recipe after this sees the same /tmp and a
    # failure fails the build.
    like( $out, qr{systemctl enable --now tmp\.mount}, 'and is mounted, not merely enabled' );
    unlike( $out, qr{queue_postrun_task\s+systemctl enable}, 'synchronously, rather than deferred' );
};

subtest 'the build payload is not somewhere tmpfs will cover it over' => sub {

    # setup.tmpl unpacks the payload and runs make from inside it.  With that in
    # /tmp, mounting a tmpfs over /tmp strands the tree and the tarball -- make
    # carries on, because its cwd is a directory it holds open, but the cleanup
    # afterwards silently removes nothing.  Found on a guest, where 196K of
    # payload was still sitting under the new mount.
    my $setup = File::Slurper::read_text("$FindBin::Bin/../setup.tmpl");

    like( $setup, qr{tar -zxf data\.tar\.gz -C /var/tmp/}, 'the payload is unpacked into /var/tmp' );
    like( $setup, qr{^cd /var/tmp/domainsetup_}m,          'and make runs from there' );

    # Anchored past /var, or it matches the /tmp inside /var/tmp and can never
    # pass -- which is how this assertion first failed against a correct file.
    unlike( $setup, qr{(?<!/var)/tmp/domainsetup_}, 'with nothing left pointing at /tmp' );
    unlike( $setup, qr{data\.tar\.gz\s+/tmp$}m,     'and the tarball does not land there either' );
};

subtest 'tmpfs escapes a percentage and leaves a byte size alone' => sub {
    my $options = sub {
        my ($size) = @_;
        my %opts   = defined $size ? ( size => $size ) : ();
        my $unit   = 'Provisioner::Recipe::tmpfs'->new(%PROV)->render_file( 'files/tmpfs.mount.tt', %G, %opts );
        my ($line) = $unit =~ m/^Options=(.*)$/m;
        return $line // q{};
    };

    # Options= is a setting systemd expands specifiers in, so a lone % begins
    # one rather than meaning itself.  A literal percent is written %%.
    like( $options->(),      qr/\bsize=50%%,/, 'the default reaches the unit doubled' );
    like( $options->('25%'), qr/\bsize=25%%,/, 'and so does any other percentage' );

    # And a size that is not a percentage must not be mangled on the way.
    like( $options->('2G'),         qr/\bsize=2G,/,         'a suffixed size is left alone' );
    like( $options->('1073741824'), qr/\bsize=1073741824,/, 'and so is a plain byte count' );

    like( $options->(), qr/\bmode=1777\b/, '/tmp stays world-writable and sticky' );
};

subtest 'tmpfs refuses a size the kernel would not take' => sub {

    # The failure is otherwise a mount that refuses at boot, on a guest nobody
    # is watching, with /tmp quietly staying on the disk.
    ## no critic (RequireQwForLiteralLists) -- one of these has a space in it
    ## and another is empty, which is the whole point and neither of which qw()
    ## can say.
    foreach my $bad ( '50 percent', 'half', '', '10%%', '-1', '0' ) {
        my $r = 'Provisioner::Recipe::tmpfs'->new(%PROV);
        ok( exception { $r->render_global( %G, size => $bad ) }, "'$bad' is refused" );
    }

    foreach my $good (qw{50% 1% 100% 2G 512M 64k 1073741824}) {
        my $r = 'Provisioner::Recipe::tmpfs'->new(%PROV);
        is( exception { $r->render_global( %G, size => $good ) }, undef, "'$good' is accepted" );
    }
};

# ----------------------------------------------------------------
# iouring: who may ask the kernel for an io_uring
# ----------------------------------------------------------------
subtest 'iouring gates on the group by default, because otherwise the group is decoration' => sub {
    my $r = 'Provisioner::Recipe::iouring'->new(%PROV);

    # 0 is the kernel's own default, so a recipe that sets it does nothing at
    # all on a stock guest -- and kernel.io_uring_group only takes effect at 1.
    my %opts = $r->validate( %G, modules => [] );
    is( $opts{mode},  1,          'mode defaults to 1' );
    is( $opts{group}, 'io_uring', 'with a group to gate on' );

    foreach my $bad ( 3, -1, 'yes' ) {
        my $fresh = 'Provisioner::Recipe::iouring'->new(%PROV);
        ok( exception { $fresh->render_global( %G, mode => $bad ) }, "mode $bad is refused" );
    }
};

subtest 'iouring collects the accounts of the recipes actually present' => sub {
    my $users = sub {
        my (@modules) = @_;
        my %opts = 'Provisioner::Recipe::iouring'->new(%PROV)->validate( %G, modules => \@modules );
        return $opts{members};
    };

    # Nothing is added for a recipe that is not on this guest, so a guest with no
    # database gets a group with nobody in it and an io_uring nothing can reach.
    # `users` is a global template variable holding the guest's accounts, so an
    # arg of that name gets handed those instead -- which is what this recipe's
    # first cut was called, and how it was caught.
    is_deeply( $users->(),          [],        'a guest running nothing that uses io_uring gets nobody' );
    is_deeply( $users->('nginx'),   [],        'nor does one running something that cannot use it' );
    is_deeply( $users->('mariadb'), ['mysql'], 'mariadb brings its own account' );

    # And what an operator wrote is kept alongside, deduplicated.
    my %opts = 'Provisioner::Recipe::iouring'->new(%PROV)->validate( %G, modules => ['mariadb'], members => [ 'mysql', 'someservice' ] );
    is_deeply( $opts{members}, [ 'mysql', 'someservice' ], 'named accounts join them, said once' );
};

subtest 'iouring defers group membership past the makefile' => sub {
    my $out = 'Provisioner::Recipe::iouring'->new(%PROV)->render_global( %G, modules => ['mariadb'] );

    like( $out, qr/groupadd --system 'io_uring'/, 'the group is made up front' );

    # mysql belongs to mariadb, whose target has not run yet -- iouring sorts
    # ahead of it.
    like( $out, qr/queue_postrun_task .*usermod -aG 'io_uring' 'mysql'/, 'and membership waits for the accounts to exist' );
    unlike( $out, qr/^usermod/m, 'rather than being attempted during the build' );

    # A gid is only knowable on the guest, and the sysctl takes the number.
    like( $out, qr/%IO_URING_GID%/, 'the gid is substituted on the guest' );
};

subtest 'the guest disks ask qemu for the io_uring backend' => sub {

    # The other half of the issue.  io='io_uring' rather than qemu's default
    # thread pool; unlike io='native' it carries no requirement about caching.
    my $xml = File::Slurper::read_text("$FindBin::Bin/../domain.xml.tmpl");
    like( $xml, qr/<driver name='qemu' type='qcow2' io='io_uring'\/>/, 'the root disk does' );

    # And so do the extra disks, which bin/provision builds rather than the
    # template -- both shapes of them.
    my $provision = File::Slurper::read_text("$FindBin::Bin/../bin/provision");
    like( $provision, qr/<driver name='qemu' type='raw' io='io_uring'\/>/,   'a raw block extra disk does' );
    like( $provision, qr/<driver name='qemu' type='qcow2' io='io_uring'\/>/, 'and a file-backed one' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
