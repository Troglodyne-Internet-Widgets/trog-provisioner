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
use Provisioner::Utils();

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp       qw(tempdir);
use File::Find();
use Provisioner::Cookbook();
use IPC::Run3();
use File::Find();
use File::Path();
use File::Rsync();
use File::Basename();
use File::Slurper();
use File::Slurper::Temp();
use Text::Xslate();

my $template_dir = "$FindBin::Bin/../templates";

# garage turns a version of latest into a release by asking for the tag list,
# and every render here goes through its enrich.  Rendering is what is tested
# here, not GitHub.
my $garage = Test::MockModule->new('Provisioner::Recipe::garage');
$garage->redefine( latest_version => sub { return 'v2.4.1' } );

# The search path bin/new_config builds: a distribution's own directory first,
# then the generic one.  Every fragment lives under ubuntu/ today, being written
# against apt and systemd; templates/ holds makefile.tt and what is genuinely
# shared.  Asking Cookbook for it is what keeps this test looking where the
# thing it is testing looks.
my $DISTRO        = 'ubuntu';
my @template_dirs = @{ Provisioner::Cookbook->template_dirs($DISTRO) };

# Every makefile fragment there is, wherever on the search path it lives.
#
# The assertions that sweep these used to glob one directory, with no check that
# the glob found anything -- so moving the fragments would have left two real
# invariants unchecked and the suite green.  Every caller counts what came back.
sub fragments {
    my @found;
    foreach my $dir (@template_dirs) {
        push( @found, glob("$dir/*.tt") );
    }
    return sort @found;
}

# Where a recipe's fragment actually is, out of that path, or undef.
#
# Not a hardcoded path: several assertions below read a fragment and skip
# quietly when they cannot find one, so a lookup that goes to the wrong place is
# a test that passes by checking nothing.
# Any template, by its path relative to a search-path directory.
sub fragment_file {
    my ($relative) = @_;

    foreach my $dir (@template_dirs) {
        ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
        return "$dir/$relative" if -f "$dir/$relative";
    }
    die "No $relative anywhere in " . join( ', ', @template_dirs ) . "\n";
}

sub fragment_for {
    my ( $recipe, $suffix ) = @_;
    $suffix //= 'tt';

    foreach my $dir (@template_dirs) {
        ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
        return "$dir/$recipe.$suffix" if -f "$dir/$recipe.$suffix";
    }
    return undef;
}

# Whether a salvage would bring a file down, asked of the thing that decides.
#
# remote_skip holds rsync patterns rather than regexes, and a pattern that reads
# exactly right and filters nothing is the failure worth catching -- which no
# amount of matching the pattern against a string can find, because the string
# is not what rsync is going to be given.  So this builds the relative path in a
# scratch tree, runs a real local rsync with the recipe's excludes, and answers
# with whether it arrived.
sub salvage_brings_down {
    my ( $relative, @skip ) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    File::Path::make_path( File::Basename::dirname("$dir/src/$relative") );
    File::Slurper::Temp::write_text( "$dir/src/$relative", "x\n" );

    my $rsync = File::Rsync->new( archive => 1, ( @skip ? ( exclude => \@skip ) : () ) );
    $rsync->exec( src => "$dir/src/", dest => "$dir/dst/" )
      or die "rsync failed in the test itself: " . join( '', @{ $rsync->err || [] } );

    return -f "$dir/dst/$relative" ? 1 : 0;
}

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
    transfer_ip                => '192.168.122.251',
    transfer_port              => 22,
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

    # Every recipe is handed these, not only the distro recipe: the fetch cache
    # runs a resolver of its own and refuses to render without them.
    resolvers => [ '192.168.1.253', '8.8.8.8' ],
    users     => [
        { name => 'admin', gecos => 'Admin User',  shell => '/bin/bash' },
        { name => 'alice', gecos => 'Alice Smith', shell => '/bin/bash' },
    ],
);

my %PROV = (
    target_packager => 'deb',
    distro          => $DISTRO,
    template_dirs   => \@template_dirs,

    # bin/new_config always sets this and nothing here did, so a recipe reading
    # it got undef: garage interpolated it into a path and died on the warning,
    # and ufw's template_files calls rmtree on "$output_dir/ufw" -- which
    # without one is rmtree('/ufw').
    output_dir => tempdir( CLEANUP => 1 ),
);

# Test that a recipe renders without error given %G merged with $extra.
sub renders_ok {
    my ( $name, $extra, $desc ) = @_;
    $desc //= $name;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    subtest $desc => sub {

        # Through Cookbook, so this exercises the distro's version of the recipe
        # -- which is where the package names are -- rather than the generic
        # class, which no build ever instantiates.
        my $class;
        my $res = exception { $class = Provisioner::Cookbook->load( $name, distro => $DISTRO ) };
        is( $res, undef, "$name loads" ) or return;

        my $r;
        $res = exception { $r = $class->new(%PROV) };
        is( $res, undef, "$name->new() succeeds" );

        # We may or may not have global/domain specific templates, but we need at least one.
        #
        # Asserting on $res, not on $@.  exception{} catches, so $@ is empty
        # whether or not the render threw -- which made this pass for every
        # recipe including the one whose minimum viable input did not validate.
        my $has_template;
        if ( fragment_for($name) ) {
            $res = exception { $r->render( %G, %$extra ) };
            is( $res, undef, "$name->render() succeeds" );
            $has_template++;
        }
        if ( fragment_for( $name, 'global.tt' ) ) {
            $res = exception { $r->render_global( %G, %$extra ) };
            is( $res, undef, "$name->render_global() succeeds" );
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
Provisioner::Utils::write_ssh_keypair( "$ddir/key.rsa", RSA => 2048, 'recipes.t' );

# Build list of known modules with required input data
my %required_config = (
    aptmirror   => { releases => ['noble'] },
    data        => { from     => '/opt/data', to => '/opt/domains' },
    imagemagick => { version  => '7.1.1-47' },
    logshipper  => { host     => 'logs.test.test' },
    mariadb     => {
        root_pw  => 's3cr3t',
        dumpfile => 'dump.sql',
        version  => '11.4.4',
    },
    tpsgi           => { routers         => ['app.psgi'] },
    gogs            => { version         => '0.13.0',        admin_password => 's3cr3t' },
    plexmediaserver => { plex_login_name => 'plexuser',      admin_mail     => 'admin@test.test' },
    openvpnclient   => { server          => 'vpn.test.test', cert_dir       => '/opt/domains/test.test.test/vpn' },
    tcms            => { tcms_dir        => 'tcms' },
    adminconfig     => { skel            => '/opt/dotfiles' },
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

# Every recipe there is, asked of the thing that already answers it.
#
# This walked lib/Provisioner/Recipe/ with File::Find and no prune, which stopped
# working the moment a distribution got a subdirectory of its own: Ubuntu/pdns.pm
# pushed a second `pdns`, every loop below ran twice, and both runs tested the
# generic class rather than the subclass.  Cookbook->names prunes, and leaves out
# the two recipes that direct a build rather than running in one.
my @available = Provisioner::Cookbook->names();

#
# Crank dat minimum viable case
#
foreach my $recipe (@available) {
    my $input = {};
    $input = $required_config{$recipe} if exists $required_config{$recipe};
    renders_ok( $recipe, $input, "$recipe with minimum viable input" );
}

# The guest rsyncs its payload off whoever is holding it -- this machine -- so
# every one of these has to name it.  When the host came out empty the recipe
# still rendered, and still looked plausible -- 'doge@:/opt/data/...' -- and only
# failed on the guest, hours later, at the point where it had already been told
# the build succeeded.
subtest 'every rsync of a payload names the machine holding it' => sub {
    my %seen;
    foreach my $recipe (qw{data adminconfig makefile openvpnclient}) {
        foreach my $tt ( grep { defined } ( fragment_for($recipe), fragment_for( $recipe, 'global.tt' ) ) ) {
            next unless -f $tt;

            # Configured the way new_config configures it, bridge and all;
            # a bare Xslate cannot render the ones using TT2 vmethods.
            my $xslate = Text::Xslate->new(
                path     => \@template_dirs,
                syntax   => 'TTerse',
                module   => [qw{Text::Xslate::Bridge::TT2}],
                function => { tabinate => Text::Xslate::html_builder( sub { $_[0] } ) },
            );
            my $out = $xslate->render_string( File::Slurper::read_text($tt), { %G, %{ $required_config{$recipe} // {} } } );
            next unless index( $out, 'rsync' ) >= 0;
            $seen{$recipe}++;
            unlike( $out, qr/\@:/, "$recipe: no empty host between the user and the path" );
            like( $out, qr/\@\Q$G{transfer_ip}\E:/, "$recipe: rsyncs from $G{transfer_ip}" );
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
rejects_missing( 'sssd', { base_dn  => 'dc=test,dc=test' },           'ldap_uri', 'sssd rejects missing ldap_uri' );
rejects_missing( 'sssd', { ldap_uri => 'ldaps://ldap.example.test' }, 'base_dn',  'sssd rejects missing base_dn' );

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
# openvpn: redirect-gateway is what decides whether a client keeps its own
# internet, so both answers want checking.  The guest test only ever sees the
# default, and either default is a change every deployed client picks up on its
# next reconnect -- so which one it is belongs under a test rather than in
# whatever the template happened to do last.
# ----------------------------------------------------------------
subtest 'openvpn pushes redirect-gateway only when the domain asks' => sub {

    # A fresh recipe per configuration: validated() memoizes on the object, so
    # two configurations through one would both get the first one's answer.
    my $vpn = sub { 'Provisioner::Recipe::openvpn'->new(%PROV) };

    my $off = $vpn->()->render_file( 'files/openvpn.server.conf.tt', %G );
    unlike( $off, qr/redirect-gateway/, 'a domain that says nothing gets no push at all' );

    my $on = $vpn->()->render_file( 'files/openvpn.server.conf.tt', %G, redirect_gateway => 1 );
    like( $on, qr/^push "redirect-gateway def1 bypass-dhcp"$/m, 'and one that asks for an exit node gets it' );

    # Unset takes OpenVPN's historical net30, a /30 per client, which upstream
    # has deprecated.  Both configurations say so, since it is not the client's
    # to choose.
    like( $_, qr/^topology subnet$/m, 'and either way the server names its topology' ) for ( $on, $off );
};

# ----------------------------------------------------------------
# ufw: validate enforces port_forward structure
# ----------------------------------------------------------------
subtest 'ufw rejects malformed port_forwards' => sub {
    my $r   = 'Provisioner::Recipe::ufw'->new(%PROV);
    my $res = exception { $r->render( %G, port_forwards => [ { from => 80 } ] ) };
    ok( $res, 'ufw dies when port_forward entry missing to' );
};

subtest 'ssh is rate limited whatever else the guest listens on' => sub {
    my $r = 'Provisioner::Recipe::ufw'->new(%PROV);

    # setup-ufw-rules applies ufw's own `limit` to nothing, because six
    # connections in thirty seconds locks a provision out of the guest it is
    # building.  This is the limit that covers ssh instead.
    my %bare = $r->validate();
    is( $bare{rate_limits}{22}, 64, 'a guest listening on nothing still limits ssh' );

    # required_recipes hands rate_limits over whole, so the key is present and a
    # default one level up never fires.  On the port itself it fills the gap in
    # the map instead, which is what the schema was always trying to say.
    my %listening = $r->validate( rate_limits => { '1194/udp' => 256 } );
    is( $listening{rate_limits}{'1194/udp'}, 256, "a recipe's own limit survives" );
    is( $listening{rate_limits}{22},         64,  'and ssh is limited beside it' );

    # An operator's own number wins outright, the way any default gives way to
    # one.  "Higher wins" is resolve_conflict's rule for two recipes disagreeing,
    # not a floor under what a person asked for.
    my %raised = $r->validate( rate_limits => { 22 => 512 } );
    is( $raised{rate_limits}{22}, 512, 'an operator can raise it' );

    my %lowered = $r->validate( rate_limits => { 22 => 2 } );
    is( $lowered{rate_limits}{22}, 2, 'and can lower it' );
};

subtest 'a rate limit says which protocol it limits' => sub {

    # The rule is written per protocol, so a limit naming only a port is a limit
    # on that port's tcp side.  For a service reached over udp that matches none
    # of its traffic, while before.rules names the port and reads as correct.
    my %vpn = 'Provisioner::Recipe::openvpn'->rate_limits( port => 1194, proto => 'udp' );
    is_deeply( [ keys %vpn ], ['1194/udp'], 'openvpn limits the protocol it listens on' );

    my %tcp = 'Provisioner::Recipe::openvpn'->rate_limits( port => 443, proto => 'tcp' );
    is_deeply( [ keys %tcp ], ['443/tcp'], 'and says so when it is configured for tcp instead' );

    # Called before validation, so the schema default is not in %opts.
    my %bare = 'Provisioner::Recipe::openvpn'->rate_limits();
    is_deeply( [ keys %bare ], ['1194/udp'], 'and defaults the way the schema does' );

    # A nameserver answers over both, and the unlimited half is the half that
    # gets used.
    my %dns = 'Provisioner::Recipe::pdns'->rate_limits();
    is_deeply( [ sort keys %dns ], [ '53', '53/udp' ], 'pdns limits both halves of port 53' );

    # A bare port still means tcp, so the recipes that only ever spoke tcp are
    # untouched by any of this.
    my %web = 'Provisioner::Recipe::nginx'->rate_limits();
    is_deeply( [ sort { $a <=> $b } keys %web ], [ 80, 443 ], 'nginx names bare ports, which are tcp' );
};

subtest 'the rate limit rule is written for the protocol it was given' => sub {
    my $script = File::Slurper::read_text("$FindBin::Bin/../scripts/setup-ufw-ratelimits");

    ok( index( $script, '*/*) proto=${spec##*/}' ) >= 0, 'the protocol is read off a port spec that carries one' );
    like( $script, qr/^\s*proto=tcp$/m,           'and defaults to tcp when there is none' );
    like( $script, qr/-p \$proto --dport \$port/, 'the rule names that protocol' );

    # Or 53/tcp and 53/udp share a table and each counts the other's traffic.
    like( $script, qr/--hashlimit-name trog\$proto\$port/, 'and gets a table of its own, per port and protocol' );
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

    # Port and protocol together are the key, so these are two services and
    # neither settles the other.
    my $split = { rate_limits => { 53 => 4096, '53/udp' => 4096 } };
    $r->reconcile( $split, { rate_limits => { 53 => 8192 } } );
    is( $split->{rate_limits}{53},       8192, 'the tcp half takes the higher' );
    is( $split->{rate_limits}{'53/udp'}, 4096, 'and the udp half is left where it was' );

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

    # Appending to an address gives somebody@example.test@this.domain, which is
    # what the old template did to every value the old schema would accept.
    like(
        $cron->()->render_file( 'files/cron.root.tt', %G, from => 'someone@example.test' ),
        qr/^MAILFROM="someone\@example\.test"$/m, 'an address is left exactly as it stands'
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
                { interval => '*/5 * * * *', cmd => '/addressed.pl', mailto => 'someone@example.test' },
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
    is( $to{'/addressed.pl'}, 'someone@example.test', 'an address is left alone' );
    is( $to{'/local.pl'},     "ops\@$d",              'a local part gets the domain' );
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

            # Per line, not per comment.  A quote opened on one line and
            # closed on the next balances across the whole block and still
            # swallows the file: Xslate does not let a string literal span a
            # newline, so the pairing shifts by one and the last quote in the
            # comment runs on to whatever quote comes next in the template.
            # Two apostrophes one line apart -- "the package's copy" and
            # "Provisioner::Recipe::ubuntu's packager invocation" -- ate two
            # install lines out of the aptmirror fragment that way.
            my $line = 0;
            foreach my $text ( split( m/\n/, $comment ) ) {
                $line++;
                foreach my $quote ( q{'}, q{"} ) {
                    my $count = () = $text =~ m/\Q$quote\E/g;
                    ok( $count % 2 == 0, "$name: line $line of a comment closes every $quote it opens" )
                      or diag $text;
                }
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
        path     => \@template_dirs,
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

# remote_files is a round trip and the second half of it is the recipe's own: the
# fetch lands the salvage under install_dir/domain, and unless that is already
# where the service reads it, some fragment has to move it.  Thirteen recipes
# named state to salvage and never wrote that leg, so the state came down, went
# back up, and sat in the domain directory while the rebuilt guest started empty.
# What the fragment does with it -- restore_state, or an importer for a database
# dump -- is its business; that it says the path at all is what this asks.
subtest 'a recipe that salvages state puts it back' => sub {
    my $install = '[% install_dir %]';
    my $domain  = '[% domain %]';

    foreach my $recipe ( sort @available ) {
        my $class    = eval { Provisioner::Cookbook->load($recipe) } or next;
        my %salvaged = eval { $class->remote_files( $install, $domain ) };
        next unless %salvaged;

        my $fragments = join "\n", map { File::Slurper::read_text($_) } grep { defined } ( fragment_for($recipe), fragment_for( $recipe, 'global.tt' ) );

        # Where a recipe says its salvage goes back, which data walks so the
        # fragment does not have to.  redis and plexmediaserver still say it in
        # their own fragments, because their destinations are owned by a service
        # that is already running and the restore has to sit between a stop and
        # a start.
        my %restores = eval { $class->restores( install_dir => $install, domain => $domain, admin_user => 'admin' ) };
        my $declared = join "\n", map { $_->{from} // q{} } values %restores;

        foreach my $source ( sort keys %salvaged ) {
            ( my $landed = $salvaged{$source} ) =~ s{/\z}{};

            # State the domain already owns needs no restore: the data target
            # rsyncs the domain directory back to exactly where it came from.
            next if index( $source, "$install/$domain" ) == 0;

            ok(
                index( $declared, "$install/$domain/$landed" ) >= 0 || index( $fragments, "$install/$domain/$landed" ) >= 0,
                "$recipe: something puts $landed back"
            ) or diag "$recipe salvages $source into $landed, and neither its restores() nor its fragment names it again";
        }
    }
};

# The other half of that, on the side that actually writes backups.
#
# remote_skip is documented as keeping a key out of "a backup sitting beside the
# database it protects", and the salvage has always honoured it -- but the backup
# recipe serves the same directories over rsyncd as root, and carried the file
# anyway.  Its own exclude was spelled `excludes`, which is not an rsyncd module
# parameter at all: rsyncd neither honours nor complains about it, so every
# pattern written there was handed to the client.
subtest 'what a recipe refuses to salvage is refused to the backup as well' => sub {
    my @skippers = grep {
        my $c = eval { Provisioner::Cookbook->load($_) };
        $c && eval { scalar $c->remote_skip() } && eval { scalar $c->remote_files( '/opt/domains', 'vm.test' ) }
    } @available;

    ok( scalar @skippers, 'there are recipes that refuse to hand something back' ) or return;

    my $backup = Provisioner::Cookbook->load('backup')->new(%PROV);
    my $conf   = $backup->render_file(
        'files/backup.rsyncd.conf.tt', %G,
        %{ $required_config{backup} },
        modules => \@skippers,
    );

    # Singular.  The plural is silently served to the client instead.
    unlike( $conf, qr/^excludes\s*=/m, 'the module uses the parameter rsyncd actually has' );

    foreach my $recipe (@skippers) {
        foreach my $pattern ( Provisioner::Cookbook->load($recipe)->remote_skip() ) {
            like( $conf, qr/^exclude = .*\Q$pattern\E/m, "$recipe: $pattern is kept out of the backup too" );
        }
    }
};

subtest 'an operator exclude is added to those rather than replacing them' => sub {
    my $backup = Provisioner::Cookbook->load('backup')->new(%PROV);

    # A target named for matrix's first salvage, which is what enrich calls it.
    my %opts = $backup->validated(
        %G, %{ $required_config{backup} },
        modules  => ['matrix'],
        excludes => { matrix1 => 'some/other/dir' },
    );

    # Somebody excluding one more directory must not silently start backing up a
    # signing key, so these concatenate.  The recipe's own patterns are not a
    # default for an operator to override.
    like( $opts{excludes}{matrix1}, qr/homeserver\.signing\.key/, 'what the recipe refuses is still refused' );
    like( $opts{excludes}{matrix1}, qr{some/other/dir},           'and what the operator asked for is there too' );
};

# A file placed out of the secret store is one the guest must never hand back:
# salvaged, it would land in the domain directory and in every backup taken of
# it, which is the exposure keeping it in the store avoids in the first place.
# So anything named in guest_secrets has to be named in remote_skip too --
# unless nothing salvages the directory it sits in, in which case there is
# nothing to skip.
subtest 'a secret placed from the store is never salvaged back' => sub {
    my $install = '/opt/domains';
    my $domain  = 'vm.test';

    foreach my $recipe ( sort @available ) {
        my $class  = eval { Provisioner::Cookbook->load($recipe) } or next;
        my %placed = eval { $class->guest_secrets( $install, $domain ) };
        next unless %placed;

        my %salvaged = eval { $class->remote_files( $install, $domain ) };
        my @skip     = eval { $class->remote_skip() };

        foreach my $path ( sort keys %placed ) {
            like( $placed{$path}{ref}, qr{\Asecret:[^/]+/[^/]+/(?:password|username)\z}, "$recipe: $path names a reference the store can keep" );
            ok( ref $placed{$path}{generate} eq 'CODE', "$recipe: and says how to make one" );

            # Only the salvages that would actually pick this file up.
            my @covering = grep { index( $path, $_ ) == 0 } keys %salvaged;
            next unless @covering;

            # Each root separately: rsync matches a pattern relative to the
            # transfer it is running, so a file that is kept out of one salvage
            # is not thereby kept out of another that also reaches it.
            foreach my $root ( sort @covering ) {
                ok(
                    !salvage_brings_down( substr( $path, length($root) ), @skip ),
                    "$recipe: $path is kept out of the salvage of $root"
                ) or diag "remote_skip has: @skip";
            }
        }
    }
};

# A salvage is only as fresh as whatever wrote it, so a recipe whose state is
# written on a schedule has to be able to say "take one now" before the fetch --
# otherwise a rebuild restores the guest to whenever the cron last ran.  What
# remote_prepare names has to be something the recipe actually puts on the guest.
subtest 'what a recipe asks the guest to run before a salvage is something it installed' => sub {
    my $install = '/opt/domains';
    my $domain  = 'vm.test';

    foreach my $recipe ( sort @available ) {
        my $class   = eval { Provisioner::Cookbook->load($recipe) } or next;
        my @prepare = eval { $class->remote_prepare( $install, $domain ) };
        next unless @prepare;

        my %generated = eval { $class->template_files() };
        my $fragments = join "\n", map { File::Slurper::read_text($_) } grep { defined } ( fragment_for($recipe), fragment_for( $recipe, 'global.tt' ) );

        foreach my $command (@prepare) {
            my ($program) = $command =~ m{\A(\S+)};

            # Installed by the fragment, under the name the command calls it by.
            my ($leaf) = $program =~ m{([^/]+)\z};
            ok(
                index( $fragments, $program ) >= 0 || ( grep { $_ eq $leaf } values %generated ),
                "$recipe: $program is something this recipe puts on the guest"
            ) or diag "remote_prepare wants $command and nothing in $recipe installs it";
        }

        ok( scalar( eval { $class->remote_files( $install, $domain ) } ), "$recipe: and it has something to salvage afterwards" );
    }
};

# A default that is generated rather than written down is a rotation: it changes
# every time bin/new_config runs, so whatever the last one authenticated -- a
# session, an admin token, another node in a cluster -- stops working at the next
# provision, and nothing anywhere says why.  Provisioner::Recipe::guest_secrets
# is how a recipe keeps one still -- in the store, placed on the guest, never in
# a default -- and this is what notices when a recipe does not.
subtest 'no recipe hands out a default that changes between runs' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    foreach my $recipe ( sort @available ) {
        my %first  = eval { Provisioner::Cookbook->spec( $recipe, output_dir => $dir ) } or next;
        my %second = eval { Provisioner::Cookbook->spec( $recipe, output_dir => $dir ) } or next;

        my $defaults = sub {
            my ($spec) = @_;
            my $props = $spec->{properties} // {};
            return { map { $_ => $props->{$_}{default} } grep { defined $props->{$_}{default} && !ref $props->{$_}{default} } keys %$props };
        };

        is_deeply( $defaults->( \%second ), $defaults->( \%first ), "$recipe: the same configuration twice running" );
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

# bin/preflight asks this of a configuration nobody has finished writing yet, so
# a recipe whose path is not filled in has to answer with nothing rather than
# with undef or with a die.
subtest 'a recipe names the directories it fetches, and copes with not being told' => sub {
    foreach my $recipe ( sort @available ) {
        my $class = eval { Provisioner::Cookbook->load($recipe) } or next;

        my @unasked = eval { $class->fetch_sources() };
        is( $@, q{}, "$recipe: asking with nothing at all does not die" );
        is_deeply( [ grep { defined } @unasked ], [], "$recipe: and names no directory" );
    }

    # The two that do name one.  Both are the operator's own files, which is why
    # nothing here creates them and something has to check they are there.
    my $adminconfig   = Provisioner::Cookbook->load('adminconfig');
    my $openvpnclient = Provisioner::Cookbook->load('openvpnclient');

    is_deeply(
        [ $adminconfig->fetch_sources( skel => '/bogus/dotfiles/somebody' ) ],
        ['/bogus/dotfiles/somebody'],
        'adminconfig fetches the skel it was given'
    );
    is_deeply(
        [ $openvpnclient->fetch_sources( cert_dir => '/bogus/vpn-certs/one' ) ],
        ['/bogus/vpn-certs/one'],
        'openvpnclient fetches its certificate directory'
    );
};

# The provisioner reaches a guest from more than one address of ours, and which
# one depends on the hypervisor: a remote one is administered over the guest's
# static address and a local one over its NAT lease.  Exempting only the address
# the payload came from left the other counted by the guest's rate limit -- and
# nothing here asserted on the value at all, which is how that survived being
# wrong in two different directions.
subtest 'ufw exempts every address the provisioner arrives from' => sub {
    my $ufw = Provisioner::Cookbook->load('ufw')->new(%PROV);

    my %got = $ufw->enrich( transfer_ips => [ '192.168.1.49', '192.168.122.251' ] );
    is_deeply(
        $got{admin_networks},
        [ '192.168.1.49', '192.168.122.251' ],
        'both of ours are exempt, not just the one the payload came from'
    );

    # What an operator wrote stays, and ours go in front of it.
    %got = $ufw->enrich(
        transfer_ips   => ['192.168.1.49'],
        admin_networks => ['10.0.0.0/8'],
    );
    is_deeply( $got{admin_networks}, [ '192.168.1.49', '10.0.0.0/8' ], 'and what was already named is kept' );

    # Said twice is still one rule.
    %got = $ufw->enrich(
        transfer_ips   => [ '192.168.1.49', '192.168.122.251' ],
        admin_networks => ['192.168.1.49'],
    );
    is_deeply( $got{admin_networks}, [ '192.168.122.251', '192.168.1.49' ], 'an address named twice is exempt once' );

    # A configuration written before there was a list of them.
    %got = $ufw->enrich( transfer_ip => '192.168.122.1' );
    is_deeply( $got{admin_networks}, ['192.168.122.1'], 'a single transfer_ip still works on its own' );

    %got = $ufw->enrich();
    is_deeply( $got{admin_networks}, [], 'and nothing at all exempts nothing' );
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
    my %files  = Provisioner::Recipe::tcms->remote_files( '/opt/domains', 'test.test.test' );
    my $wanted = '/opt/domains/test.test.test/tCMS/config/';
    ok(
        ( grep { index( $wanted, $_ ) == 0 } keys(%files) ),
        'tCMS salvages its config directory, whichever root covers it'
    ) or diag "salvages: " . join( ', ', sort keys %files );

    # And the checkout it sits in, which is state as much as the content is: a
    # site pinned to a revision, or carrying a patch nobody pushed, came back as
    # whatever master was that morning without this.
    ok(
        ( grep { index( '/opt/domains/test.test.test/tCMS/.git', $_ ) == 0 } keys(%files) ),
        'and the checkout, so a rebuild serves the commit the guest was serving'
    ) or diag "salvages: " . join( ', ', sort keys %files );

    my @skip = Provisioner::Recipe::tcms->remote_skip();
    ok( scalar(@skip),                                'and says something in it must stay behind' );
    ok( !salvage_brings_down( 'secrets.key', @skip ), 'which is the vault key' );

    # And nothing else out of that directory, since the rest of it is the state
    # the salvage exists for.
    foreach my $keep (qw{auth.db main.cfg has_users}) {
        ok( salvage_brings_down( $keep, @skip ), "$keep still comes over" );
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

    # configd joins a parameter across the fragments it finds, so a second
    # domain adds to what the first one set rather than replacing it.
    like( $out, qr{main\.cf\.d/50-\Q$G{domain}\E},        'main.cf gets a fragment named for the domain' );
    like( $out, qr{opendmarc\.conf\.d/50-\Q$G{domain}\E}, 'and so does opendmarc.conf' );

    # Every one of these was a single file at a fixed path that the next domain
    # overwrote, taking the previous one's mail with it.
    foreach my $table (qw{virtual_maps virtual_aliases transport_maps sdd_relay_maps sender_login header_checks}) {
        like( $out, qr{/etc/postfix/domains/\Q$G{domain}\E/$table\b}, "$table is this domain's own file" );
    }

    # Overwriting a file configd generates works until the next restart, and
    # then silently does not, so the guest-wide parts go in as fragments too.
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

    # The setup script unpacks the payload and runs make from inside it.  With
    # that in /tmp, mounting a tmpfs over /tmp strands the tree and the tarball
    # -- make carries on, because its cwd is a directory it holds open, but the
    # cleanup afterwards silently removes nothing.  Found on a guest, where 196K
    # of payload was still sitting under the new mount.
    #
    # Rendered rather than read: these paths are about what the guest ends up
    # running, and the fragment they are in is a template.
    my $setup = Text::Xslate->new(
        path   => \@template_dirs,
        syntax => 'TTerse',
        module => [qw{Text::Xslate::Bridge::TT2}],
    )->render(
        "files/$DISTRO.setup.sh.tt",
        {
            domain        => 'vm.example.test',
            transfer_ip   => '192.168.122.251',
            transfer_port => 22,
            transfer_user => 'transfer',
            payload_dir   => '/opt/domains',
        }
    );

    like( $setup, qr{data\.tar\.gz /var/tmp$}m,            'the payload is fetched into /var/tmp' );
    like( $setup, qr{tar -zxf data\.tar\.gz -C /var/tmp/}, 'unpacked there' );
    like( $setup, qr{^cd /var/tmp/domainsetup_}m,          'and make runs from there' );

    # The cleanup repeats both paths rather than deriving them, so it is where
    # it can disagree with the three lines above.
    like( $setup, qr{^rm -rf /var/tmp/domainsetup_\S+ /var/tmp/data\.tar\.gz}m, 'and both are cleared away from there' );
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

    # But only the recipes this one knows about contribute a unit to restart:
    # an account named by hand has none here to name.
    is_deeply( $opts{restart_units}, ['mariadb'], 'and only the known services get restarted' );
};

subtest 'iouring defers group membership past the makefile' => sub {
    my $out = 'Provisioner::Recipe::iouring'->new(%PROV)->render_global( %G, modules => ['mariadb'] );

    like( $out, qr/groupadd --system 'io_uring'/, 'the group is made up front' );

    # mysql belongs to mariadb, whose target has not run yet -- iouring sorts
    # ahead of it.
    like( $out, qr/queue_postrun_task .*usermod -aG 'io_uring' 'mysql'/, 'and membership waits for the accounts to exist' );
    unlike( $out, qr/^usermod/m, 'rather than being attempted during the build' );

    # A process reads its groups at start and not again, and mariadb was started
    # by its own recipe during the makefile -- so without a restart it runs its
    # whole first life outside the group it was just put in.
    like( $out, qr/queue_postrun_task systemctl try-restart 'mariadb'/, 'and the service is restarted so it picks the group up' );

    # In that order: postrun tasks run in the order they were queued, and a
    # restart ahead of the usermod would restart it back out of the group.
    my ($usermod) = $out =~ m/\A(.*?)usermod -aG/s;
    my ($restart) = $out =~ m/\A(.*?)try-restart/s;
    ok( length($usermod) < length($restart), 'with the membership queued first' );

    # A gid is only knowable on the guest, and the sysctl takes the number.
    like( $out, qr/%IO_URING_GID%/, 'the gid is substituted on the guest' );
};

# ----------------------------------------------------------------
# mariadb: from the pinned apt repository, not the bintar
# ----------------------------------------------------------------
subtest 'mariadb installs from its own repository at the exact release' => sub {
    my $r   = 'Provisioner::Recipe::mariadb'->new(%PROV);
    my $out = $r->render( %G, %{ $required_config{mariadb} } );

    # The bintar pins exactly too, and is built against libaio -- so InnoDB
    # cannot use io_uring however the guest is configured.  The repository
    # builds are Debian's and depend on liburing2.
    like( $out, qr{install_mariadb\.sh "11\.4\.4"}, 'the installer gets the version it was given' );

    # The fragment asks for the install; how to do it is the script's, which is
    # what keeps the file holding root_pw out of /etc/mysql when the SQL fails.
    like(
        $out, qr{install_mariadb\.sh "[^"]+" "mariadb-provisioner\.cnf" "secure_installation\.sql"},
        'the config and the secure-installation sql are handed to it'
    );

    # Asking for the mariadb packages up front would have cloud-init install
    # Ubuntu's before the makefile runs, only for the pin to downgrade them.
    my @deps = $r->deps();
    is_deeply( [ grep { index( $_, 'maria' ) >= 0 } @deps ], [], 'the mariadb packages are not cloud-init deps' );
};

subtest 'mariadb writes credentials the accounts that need them can use' => sub {
    my $r = 'Provisioner::Recipe::mariadb'->new(%PROV);

    # Clients read ~/.my.cnf without being told to, and recipes outside this
    # repository point --defaults-file at one.  The bintar layout had a single
    # /opt/mysql/my.cnf carrying these; dropping it broke them.
    my $out = $r->render( %G, %{ $required_config{mariadb} } );
    like( $out, qr{mariadb-client\.cnf /root/\.my\.cnf},                    'root gets one' );
    like( $out, qr{-o \Q$G{admin_user}\E .*mariadb-client\.cnf.*\.my\.cnf}, 'and so does the admin' );
    like( $out, qr{install -m 0600 },                                       'both 0600, since they carry the password' );

    like( $out, qr{mariadb-client-service\.cnf.*\Q$G{user}\E}, 'and the service user gets its own' );

    # Unless it is the admin, where one file per home means the service one
    # would land on top of theirs.
    my $same = 'Provisioner::Recipe::mariadb'->new(%PROV)->render( %G, %{ $required_config{mariadb} }, user => $G{admin_user} );
    unlike( $same, qr{mariadb-client-service\.cnf}, 'not when the service user is the admin' );

    # --defaults-file replaces the defaults rather than adding to them, so a
    # file used that way has to name the socket itself.
    my $cnf      = 'Provisioner::Recipe::mariadb'->new(%PROV)->render_file( 'files/mariadb.client.cnf.tt', %G, %{ $required_config{mariadb} } );
    my @sections = $cnf =~ m/^\[(\w[\w-]*)\]$/gm;
    ok( scalar @sections, 'the credentials file has sections' );
    foreach my $section (@sections) {
        my ($body) = $cnf =~ m/^\[\Q$section\E\]\n(.*?)(?=^\[|\z)/ms;
        like( $body, qr/^socket = /m, "[$section] names the socket" );
    }

    # And the service user's has no password: what that account may do is the
    # dump's business.
    my $service = 'Provisioner::Recipe::mariadb'->new(%PROV)->render_file( 'files/mariadb.client.service.cnf.tt', %G, %{ $required_config{mariadb} }, user => 'www-data' );
    unlike( $service, qr/^\s*password\s*=/m, 'the service account gets no password' );
    like( $service, qr/^user = www-data$/m, 'just the socket and who to be' );
};

subtest 'a changed root password re-runs the securing' => sub {
    my $script = File::Slurper::read_text("$FindBin::Bin/../scripts/install_mariadb.sh");

    # A bare "has this ever run" marker leaves the database on the old password
    # while every .my.cnf claims the new one, and the first thing to notice is a
    # backup that stopped working.
    like( $script, qr/sha256sum < "\$SECURE_SQL"/, 'the marker is keyed on the SQL, not on having run' );
};

subtest 'the installer configures the server before anything uses it' => sub {
    my $script = File::Slurper::read_text("$FindBin::Bin/../scripts/install_mariadb.sh");

    # Order is the whole of it.  The drop-in carries sql_mode and log_bin, so a
    # schema loaded before it is applied is a schema loaded under the package's
    # defaults and absent from the binlog the pinning exists to protect.
    my $config = index( $script, '/etc/mysql/mariadb.conf.d/60-provisioner.cnf' );
    my $secure = index( $script, 'mariadb < "$SECURE_SQL"' );
    my $schema = index( $script, 'mariadb < "$SCHEMA"' );

    ok( $config > 0 && $secure > 0 && $schema > 0, 'it does all three' );
    ok( $config < $secure,                         'the configuration is in place before the server is secured' );
    ok( $secure < $schema,                         'and the schema loads last' );

    # The password is in that file, so it does not survive the SQL failing.
    # Including on the run that skips securing, since the file holds root_pw
    # whether or not anything reads it.
    my ($trap) = $script =~ m/\A(.*?)trap 'rm -f "\$SECURE_SQL"' EXIT/s;
    ok( defined $trap,                            'the secure-installation sql is removed on the way out' );
    ok( defined $trap && length($trap) < $secure, 'from before the run that would use it, not inside it' );
};

subtest 'install_mariadb.sh keeps the version it was handed' => sub {
    my $script = File::Slurper::read_text("$FindBin::Bin/../scripts/install_mariadb.sh");

    # /etc/os-release defines VERSION -- and NAME, and ID -- so sourcing it into
    # the script's own scope renamed the release we were asked for to
    # "24.04.4 LTS (Noble Numbat)" and sent it looking for a repository under
    # that.  A guest found this; nothing here could have.
    like( $script, qr/CODENAME=\$\(\. \/etc\/os-release/, 'the codename is read in a subshell instead' );
    like( $script, qr/^MARIADB_VERSION=\$1$/m,            'and what it was handed keeps a name of its own' );
};

subtest 'the root password survives being put in a SQL string' => sub {
    my $sql = sub {
        my ($pw)   = @_;
        my $out    = 'Provisioner::Recipe::mariadb'->new(%PROV)->render_file( 'files/mysql.secure_installation.tt', %G, %{ $required_config{mariadb} }, root_pw => $pw );
        my ($line) = $out =~ m/^(ALTER USER.*)$/m;
        return $line // q{};
    };

    # Xslate escapes for HTML by default, and this is SQL: without mark_raw an
    # apostrophe becomes &#39; and the account gets a password nobody typed.
    unlike( $sql->(q{pa'ss}), qr/&#39;/, 'no HTML escaping reaches the SQL' );

    # And a quote or a backslash would otherwise end the literal early.
    like( $sql->(q{pa'ss}),  qr/PASSWORD\('pa\\'ss'\)/,  'a quote is escaped for the SQL literal' );
    like( $sql->(q{pa\\ss}), qr/PASSWORD\('pa\\\\ss'\)/, 'and so is a backslash' );

    # unix_socket has to survive: it is how root connects from this machine, and
    # everything the recipe runs afterwards depends on it.
    like( $sql->('plain'), qr/IDENTIFIED VIA unix_socket OR mysql_native_password/, 'socket auth is kept alongside the password' );

    # An option file has its own rules: the value is double-quoted there, so a
    # double quote ends it early where a single one is harmless.
    my $cnf = sub {
        my ($pw)   = @_;
        my $out    = 'Provisioner::Recipe::mariadb'->new(%PROV)->render_file( 'files/mariadb.client.cnf.tt', %G, %{ $required_config{mariadb} }, root_pw => $pw );
        my ($line) = $out =~ m/^password = (.*)$/m;
        return $line // q{};
    };
    is( $cnf->(q{pa"ss}),  q{"pa\\"ss"},  'a double quote is escaped for the option file' );
    is( $cnf->(q{pa\\ss}), q{"pa\\\\ss"}, 'and so is a backslash' );
    unlike( $cnf->(q{pa'ss}), qr/&#39;/, 'and nothing is HTML-escaped on the way' );
};

subtest 'a vhost serves files only where a recipe said it has some' => sub {
    my $vhost = sub {
        my (%vhosts) = @_;

        # A fresh object per configuration: validate is memoized on the object,
        # so asking one twice with different vhosts answers with the first.
        return 'Provisioner::Recipe::nginxproxy'->new(%PROV)->render_file( 'files/nginx.domain.conf.tt', %G, vhosts => \%vhosts );
    };

    # What a reverse proxy in front of gogs or synapse configures.  static_dir
    # used to fall back to www/, so this got root install_dir/domain/www -- a
    # directory the recipe never asked for, on every domain that proxies.
    my $proxy = $vhost->( 443 => { ssl => 1, proxy_uri => 'http://127.0.0.1:3000' } );
    unlike( $proxy, qr/^\s*root\s/m, 'a vhost with no static_dir is given no root' );
    like( $proxy, qr!location \s+ / \s+ \{ .*? proxy_pass!xs, 'and proxies from / rather than falling through to a named location' );
    unlike( $proxy, qr/try_files/, 'with nothing to try before proxying' );

    # And the other half: a recipe that does serve files still gets exactly what
    # it named, with the proxy behind it as the fallback.
    my $static = $vhost->( 443 => { ssl => 1, proxy_uri => 'run/app.sock', static_dir => 'www/static' } );
    like( $static, qr{^\s*root /opt/domains/test\.test\.test/www/static;}m, 'a declared static_dir is the root' );
    like( $static, qr/try_files \$uri .*\@default/,                         'statics are tried before the proxy' );
    like( $static, qr/location \@default \{/,                               'and the proxy is the fallback it names' );

    # nocache_prefix and auth_statics both serve files out of the static root.
    # matrix sets a nocache_prefix and no static_dir, so this block used to be
    # rendered with the www/ fallback under it.
    my $nocache = $vhost->( 443 => { ssl => 1, proxy_uri => 'http://127.0.0.1:8008', nocache_prefix => '^~ /(_matrix)/' } );
    unlike( $nocache, qr/^\s*root\s/m, 'a nocache_prefix with no static_dir serves no files either' );

    # public_dir is an alias rather than a root, so it is the one thing here that
    # does not need a static_dir behind it.  deluged sets it and nothing else.
    my $public = $vhost->( 443 => { ssl => 1, proxy_uri => 'http://127.0.0.1:8112', public_dir => 'torrents' } );
    like( $public, qr{^\s*alias /opt/domains/test\.test\.test/torrents;}m, 'a public_dir is still served without one' );
    unlike( $public, qr/^\s*root\s/m, 'and still brings no root with it' );
};

subtest 'nginxproxy opens exactly as much of the domain directory as a docroot needs' => sub {
    my $frag = sub {
        my (%vhosts) = @_;

        # A fresh object per configuration, for the same reason the vhost
        # closure above uses one: validate is memoized on the object.
        return 'Provisioner::Recipe::nginxproxy'->new(%PROV)->render( %G, vhosts => \%vhosts );
    };

    # data leaves the domain directory 0750 user:admin_user, and www-data is
    # neither -- but a pure proxy has nothing under there nginx ever opens, so
    # granting it traversal would be exposure with nothing to show for it.
    my $proxy = $frag->( 443 => { ssl => 1, proxy_uri => 'http://127.0.0.1:3000' } );
    unlike( $proxy, qr/chmod o\+x/, 'a vhost with no static_dir gets no traversal at all' );

    # www/static is two directories under the domain root, and data leaves both
    # of them 0750 once it has actually rsynced content down -- so both need
    # opening, the way a guest seeded with real content under www/ showed only
    # one of them was.
    my $static = $frag->( 443 => { ssl => 1, proxy_uri => 'run/app.sock', static_dir => 'www/static' } );
    like( $static, qr{chmod o\+x '/opt/domains/test\.test\.test'$}m, 'the domain directory gets traversal' );
    like(
        $static, qr{chmod o\+x '/opt/domains/test\.test\.test/www'$}m,
        'and so does the directory static_dir sits under'
    );
    unlike(
        $static, qr{chmod o\+x '/opt/domains/test\.test\.test/www/static'},
        'but not static_dir itself -- that is a group change, not a traverse bit'
    );

    # The docroot itself is handed to www-data by group, recursively: data
    # already rsynced whatever the domain has to serve before this fragment
    # ever runs, and a non-recursive chown left everything under the top
    # directory in the admin group, unreadable to www-data despite the
    # directory itself claiming to be theirs.
    like(
        $static,
        qr{chown -R \Q$G{user}\E:www-data '/opt/domains/test\.test\.test/www/static'},
        'static_dir is chowned recursively, not just retagged at the top'
    ) or diag $static;

    # And setgid on every directory under it, so a file the running application
    # writes after this recipe has finished lands in that group too -- the same
    # arrangement redis and mail keep their own later writes in.
    like(
        $static,
        qr{find '/opt/domains/test\.test\.test/www/static' -type d -exec chmod g\+s},
        'and every directory under static_dir is left setgid for what gets written later'
    );
};

subtest 'gogs is served where the vhost actually answers' => sub {
    my $ini = 'Provisioner::Recipe::gogs'->new(%PROV)->render_file( 'files/gogs.app.ini.tt', %G, %{ $required_config{gogs} }, secret_key => q{} );

    # nginxproxy writes one vhost, for the domain and the aliases new_config
    # gives it, and a git. is not among them.  Every clone URL, login redirect
    # and webhook gogs emitted named a host nobody had made.
    like( $ini, qr{^ROOT_URL\s*=\s*https://\Qtest.test.test\E/$}m, 'ROOT_URL is the domain itself' );
    like( $ini, qr{^DOMAIN\s*=\s*\Qtest.test.test\E$}m,            'and so is DOMAIN' );

    # The files stay under git.$domain.  That is a directory name, and moving it
    # would strand what remote_files salvaged off every guest that has one.
    like( $ini, qr{^ROOT\s*=\s*/opt/domains/git\.test\.test\.test/repos$}m, 'while the repository store is left where it is' );
};

subtest 'a recipe that needs a port open declares a profile rather than a rule' => sub {

    # setup-ufw-rules opens with `ufw reset`, which drops every rule on the
    # guest, and the ufw target runs after the recipes that depend on it.  So a
    # rule a fragment adds itself is deleted a few targets later, and the only
    # reason ldap looked like it worked was that slapd ships a profile covering
    # the port it defaults to.  Profiles live in /etc/ufw/applications.d, which
    # the reset leaves alone, and setup-ufw-rules allows every one it finds.
    my @fragments = fragments();
    ok( scalar @fragments, 'there are fragments to check' );

    foreach my $tt (@fragments) {
        next if $tt =~ m{/ufw(?:[.]global)?[.]tt\z};

        my $body = File::Slurper::read_text($tt);

        # Comments say what used to be here and why it moved; the rule itself is
        # what must not come back.  Directive and comment markers are stripped
        # so a template comment quoting the old line does not read as one.
        $body =~ s/\[%#.*?%\]//gs;
        $body =~ s/^\s*#.*$//gm;

        my ($offender) = $body =~ m/^([^\n]*\bufw\s+(?:allow|deny|limit|reject)\b[^\n]*)$/m;
        is( $offender, undef, ( File::Basename::basename($tt) ) . ' adds no firewall rule of its own' );
    }
};

# bin/new_config renders every recipe with its configuration and then with
# modules, the recipes on the guest, so a field by that name is one no domain can
# set and whose value is never what the recipe meant.  The perl recipe had one,
# and on a guest cpanm was asked to install nginx and ufw.
#
# full_aliases is written over the same way, and is not checked: mail declares
# it to describe what new_config hands it, which is the same thing.
subtest 'no recipe takes a field bin/new_config writes over' => sub {
    foreach my $recipe ( sort @available ) {
        my %spec = eval { Provisioner::Cookbook->spec($recipe) } or next;
        ok( !exists $spec{properties}{modules}, "$recipe takes no field called modules" );
    }

    # And what it builds from its own list, given the list new_config hands it.
    my $out = Provisioner::Cookbook->load( 'perl', distro => $DISTRO )->new(%PROV)->render( %G, modules => [qw{nginx ufw perl}] );
    unlike( $out, qr/'nginx'|'ufw'/, 'perl installs no recipe that is on the guest' );
    unlike( $out, qr/cpan_install/,  'and nothing at all when nothing was handed to it' );
};

# The counterpart of the rule above, for CPAN.  A recipe hands what it installs
# to the perl recipe, whose target reaches CPAN through scripts/cpan_install and
# nothing else, which is what puts every install under cpan_notest.  A
# fragment calling cpanm itself goes around both, and the build that finds out
# is the one where CPAN is down.
#
# makefile.tt is not a recipe's: its testdeps target is a line nothing feeds.
subtest 'no fragment calls cpanm itself' => sub {
    my @fragments = grep { !m{/makefile[.]tt\z} } fragments();
    ok( scalar @fragments, 'there are fragments to check' );

    foreach my $tt (@fragments) {
        my $body = File::Slurper::read_text($tt);
        $body =~ s/\[%#.*?%\]//gs;
        $body =~ s/^\s*#.*$//gm;

        my ($offender) = $body =~ m/^([^\n]*\bcpanm\b[^\n]*)$/m;
        is( $offender, undef, ( File::Basename::basename($tt) ) . ' leaves CPAN to the perl recipe' );
    }
};

subtest 'the firewall reset is one that can actually run' => sub {
    my $script = File::Slurper::read_text("$FindBin::Bin/../scripts/setup-ufw-rules");

    # `ufw reset` prompts, and a provision has no terminal to answer from: it
    # read EOF, printed "Aborted", and the first thing the target did was
    # nothing.  Everything after it in that list is only true if this runs.
    like( $script, qr/\[qw\{--force reset\}\]/, 'the reset is forced' );
};

subtest 'ufw own limit is applied to nothing, and cannot come back by accident' => sub {
    my $script = File::Slurper::read_text("$FindBin::Bin/../scripts/setup-ufw-rules");
    ( my $code = $script ) =~ s/^\s*#.*$//gm;

    # Six connections in thirty seconds, hardcoded in ufw with no per-profile
    # knob.  Applied to a web profile it rate limited real visitors off the site
    # after one page load; applied to ssh it locked the provisioner out of the
    # guest it was building, because a provision opens far more than six.
    #
    # It stopped being applied to anything, and then sat here for two rounds of
    # changes as a branch under a hash nothing ever filled -- reading exactly
    # like the mechanism while being unreachable.  This is what makes putting it
    # back a decision rather than an oversight.
    unlike( $code, qr/^\s*push\(.*"limit"/m, 'no rule is pushed with ufw limit' );

    # The delete is not the same thing and has to stay: it takes off limits an
    # older provision left on a profile, which ufw keeps alongside an allow
    # rather than displacing with it.
    like( $code, qr/\Qufw --force delete limit in\E/, 'while an older limit is still cleaned off' );

    # Rate limiting lives in the other script, and the exemptions with it.
    my $limits = File::Slurper::read_text("$FindBin::Bin/../scripts/setup-ufw-ratelimits");
    like( $limits, qr/hashlimit/, 'the real limits are hashlimit rules elsewhere' );
    like( $limits, qr/EXEMPT/,    'and that is where admin networks are exempted' );

    # So the fragment must not hand networks to a script with nothing to exempt
    # them from.  They were still being passed after the branch went dead.
    my $fragment = File::Slurper::read_text( fragment_file('ubuntu/ufw.tt') );
    unlike( $fragment, qr{setup-ufw-rules\S*\s*\[%\s*FOR}, 'and none are passed to the script that no longer limits' );
    like( $fragment, qr/setup-ufw-ratelimits.*EXEMPT/, 'only to the one that does' );
};

subtest 'the ufw target runs after every recipe that installs a profile' => sub {

    # setup-ufw-rules allows whatever `ufw app list` reports and opens with a
    # reset that restores before.rules from the packaged copy.  A recipe whose
    # target runs after it gets a profile nothing allowed, and rules nothing
    # kept.  This held by alphabet alone until makefile.tt was made to say it.
    my $mf = File::Slurper::read_text("$template_dir/../templates/makefile.tt");

    like( $mf, qr/\Qall:\E.*\Qmodules_ordered\E.*ufw_fragment/s, 'ufw is named after the ordered modules' );
    like( $mf, qr/\QIF ufw_fragment\E/,                          'and only when there is a ufw target to name' );

    # And bin/new_config is what takes it out of the ordered set, or there would
    # be two targets of the same name and make would keep the second.
    my $gen = File::Slurper::read_text("$FindBin::Bin/../bin/new_config");
    like( $gen, qr/my \$ufw_fragment = delete \$fragments\{ufw\}/,         'the fragment is lifted out of the module set' );
    like( $gen, qr{grep \{ \$_ ne "/etc/provisioner/state/\$fqdn/ufw" \}}, 'and off the prerequisite list with it' );
};

subtest 'no firewall profile is named after something in /etc/services' => sub {

    # ufw refuses to load a profile whose section name is also a service name,
    # and says so only as a warning on stderr -- so the profile is absent from
    # `ufw app list`, no rule is ever made from it, and nothing anywhere fails.
    # [ldap] and [redis] were both shipped this way, which meant the port each
    # of those recipes exists to expose was never opened by its own profile.
    ## no critic (ValuesAndExpressions::ProhibitFiletest_r)
    plan skip_all => 'no /etc/services to check against' unless -r '/etc/services';

    my %service;
    foreach my $line ( split m/\n/, File::Slurper::read_text('/etc/services') ) {
        next if $line =~ m/\A\s*[#]/;
        my ($name) = $line =~ m/\A(\S+)\s/ or next;

        # Case sensitively, which is how ufw compares them: [OpenVPN] is
        # accepted where an openvpn would not be.
        $service{$name} = 1;
    }

    my @profiles = sort ( glob("$template_dir/files/ufw.*.tt"), glob("$template_dir/files/*.ufw.conf.tt") );
    ok( scalar @profiles, 'there are firewall profiles to check' );

    foreach my $tt (@profiles) {
        my $body = File::Slurper::read_text($tt);

        # Comments here explain which names were skipped and why, so they name
        # the very things being tested for.
        $body =~ s/\[%#.*?%\]//gs;

        foreach my $section ( $body =~ m/^\[([^\]]+)\]\s*$/gm ) {
            ok( !$service{$section}, ( File::Basename::basename($tt) ) . ": [$section] is a name ufw will load" )
              or diag "ufw skips [$section]: also in /etc/services";
        }
    }
};

subtest 'a recipe that says where its state goes back depends on the thing that puts it there' => sub {
    my %opts = ( install_dir => '[% install_dir %]', domain => '[% domain %]', admin_user => 'admin' );

    foreach my $recipe ( sort @available ) {
        my $class = eval { Provisioner::Cookbook->load($recipe) } or next;

        my %restores = eval { $class->restores(%opts) };
        next unless %restores;

        # Asked of the base, which is what bin/new_config asks: it merges the
        # base's answer alongside the recipe's own, so a recipe that overrides
        # required_recipes without chaining to SUPER -- six of them do -- still
        # owes data what the base says it owes.  Asking the recipe here instead
        # would be testing whether it happened to chain, which is not the thing
        # that has to be true.
        my %required = eval { Provisioner::Recipe::required_recipes( $class, %opts ) };
        ok( $required{data}, "$recipe asks for data, so its restores reach it" )
          or diag "$recipe declares restores() but the base does not turn that into a dependency on data";

        # And every entry says where it is coming from, because that is the half
        # nothing else can supply.
        foreach my $to ( sort keys %restores ) {
            ok( length( $restores{$to}{from} // q{} ), "$recipe: $to says what it is restored from" );
        }
    }
};

subtest 'the masquerade rules are written after the firewall is reset' => sub {

    # setup-masquerade edits before.rules, and the ufw target's reset restores
    # that file from the packaged copy.  Written during the makefile the rules
    # went in before the reset took them out again, so a VPN client connected
    # and routed nowhere.  post_install runs after every target.
    my $out = 'Provisioner::Recipe::openvpn'->new(%PROV)->render( %G, %{ $required_config{openvpn} // {} } );

    like( $out, qr{queue_postrun_task \S*/setup-masquerade}, 'the masquerade write is deferred past the makefile' );
};

subtest 'nothing restores state from a fragment that data could do' => sub {

    # data walks the map now.  The two that still call restore_state themselves
    # are the ones whose destination is owned by a service cloud-init has already
    # started, so the restore has to sit between a stop and a start inside their
    # own target -- which is not something the data target can be in the middle
    # of.  Anything else doing it by hand is a recipe that has not been moved
    # over, and two mechanisms for one job is what this went to some trouble to
    # stop being true.
    my @allowed = qw{data redis plexmediaserver};

    my @fragments = fragments();
    ok( scalar @fragments, 'there are fragments to check' );

    foreach my $tt (@fragments) {
        my $name = File::Basename::basename( $tt, '.tt' );
        $name =~ s/[.]global\z//;
        next if grep { $_ eq $name } @allowed;

        my $body = File::Slurper::read_text($tt);
        $body =~ s/\[%#.*?%\]//gs;

        unlike( $body, qr{/restore_state\b}, "$name leaves the restoring to data" );
    }
};

# --- Where the package names live --------------------------------------------
#
# Packages live in a subclass per distribution, and the failure mode that buys
# is a quiet one: a recipe with no subclass for the distribution in hand
# inherits the base class's empty deps() and installs nothing at all, which
# nothing notices until a service will not start twenty minutes into a build.
#
# So this is what notices.  It runs for every distribution there is, so adding
# one and forgetting a recipe fails here rather than on a guest.
subtest 'every recipe that needs packages has them, for every distribution' => sub {
    my @distros = Provisioner::Cookbook->distros();
    ok( scalar @distros, 'there is at least one distribution' );

    foreach my $distro (@distros) {
        my %provisioner = ( %PROV, distro => $distro, template_dirs => Provisioner::Cookbook->template_dirs($distro) );

        foreach my $recipe ( sort @available ) {
            my $generic  = "Provisioner::Recipe::$recipe";
            my $specific = Provisioner::Cookbook->load( $recipe, distro => $distro );

            # Nothing to say for a recipe that installs nothing: most of them
            # reach the network through something that does.
            next if $specific eq $generic && !$generic->can('deps');

            my @deps = $specific->new(%provisioner)->deps( %{ $required_config{$recipe} // {} } );
            next unless @deps;

            isnt( $specific, $generic, "$recipe names its $distro packages in a $distro subclass" );
            ok( $specific->isa($generic), "which is a $generic" );
        }
    }
};

subtest 'no recipe still asks which packager it is being built for' => sub {

    # The subclass is the answer now, so nothing should still be asking.
    my @asking;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless m/[.]pm\z/;
                push( @asking, $File::Find::name ) if index( File::Slurper::read_text($File::Find::name), 'target_packager' ) >= 0;
            },
        },
        "$FindBin::Bin/../lib/Provisioner/Recipe"
    );

    is_deeply( \@asking, [], 'target_packager is nowhere in the recipes' ) or diag "still asking: @asking";
};

subtest 'a distribution gets its own version of a recipe, or the generic one' => sub {

    # The lookup that decides which class a build actually instantiates.
    is( Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' ), 'Provisioner::Recipe::Ubuntu::nginx', 'the subclass where there is one' );
    is( Provisioner::Cookbook->load( 'nginx', distro => 'plan9' ),  'Provisioner::Recipe::nginx',         'and the recipe itself where there is not' );
    is( Provisioner::Cookbook->load('nginx'), 'Provisioner::Recipe::nginx', 'as with no distribution named at all' );

    # The fragment is shared: what a distribution changes is deps, not the
    # makefile, so a subclass has to answer to the same template name.
    my $r = Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' )->new(%PROV);
    is( $r->{template},        'nginx.tt',        'and looks for the same fragment' );
    is( $r->{global_template}, 'nginx.global.tt', 'and the same global one' );
};

subtest 'the two enumerations of what a recipe is agree' => sub {

    # Cookbook->names answers by name, because it deliberately loads nothing;
    # is_module answers by asking the class.  Two mechanisms for one fact is
    # two mechanisms that can drift.
    foreach my $recipe (@available) {
        ok( Provisioner::Cookbook->load($recipe)->new(%PROV)->is_module, "$recipe is offered as something to put on a guest, and is one" );
    }

    foreach my $director ( Provisioner::Cookbook->directors() ) {
        my $class = Provisioner::Cookbook->load($director);
        ok( !$class->new( %PROV, template_dirs => [] )->is_module, "$director is not offered, and directs the build instead" );
        ok( Provisioner::Cookbook->has($director),                 "though it is still a recipe you can ask for by name" );
    }
};

subtest 'the two halves of the mirror path agree' => sub {

    # A guest is told to fetch from <mirror><path> by the distro recipe, and the
    # mirror serves that path because the aptmirror recipe was told the same
    # one.  They are one string written in two files, so nothing but this stops
    # them drifting apart into a mirror nobody can fetch from.
    my %aptmirror = Provisioner::Cookbook->defaults('aptmirror');

    foreach my $distro ( Provisioner::Cookbook->distros() ) {
        is(
            $aptmirror{path}, Provisioner::Cookbook->load($distro)->mirror_path,
            "aptmirror serves the path $distro tells its guests to fetch from"
        );
    }
};

subtest 'the two halves of the log path agree about the port' => sub {

    # A guest is told to send to <host>:<port> by logshipper, and the collector
    # listens on the port logcollector was told.  They are one number written in
    # two files, and a fleet whose halves disagree ships everything into a closed
    # port and says nothing about it -- which is exactly the failure this pair
    # was written to end.
    my %ship    = Provisioner::Cookbook->defaults('logshipper');
    my %collect = Provisioner::Cookbook->defaults('logcollector');

    is( $ship{port},     $collect{port},     'logshipper sends where logcollector listens' );
    is( $ship{protocol}, $collect{protocol}, 'over the transport it is accepting' );
};

subtest 'every host a template fetches from is declared in fetch_hosts' => sub {

    # The heuristic that found nine undeclared hosts: a URL on the same line as
    # something that fetches it.  What it cannot see is a host a program reaches
    # on its own -- nvm downloads node from nodejs.org and no template writes
    # that down -- so this catches an omission that is written, and a recipe
    # still has to think about the rest.
    my %declared = map { $_ => 1 } Provisioner::Cookbook->fetch_hosts;

    # Deliberately elsewhere.  Apt repositories do not go through the cache: a
    # guest reaches the archive through aptmirror's mirrorlist, and the cache's
    # freshness classes do not map onto InRelease and Packages, where a
    # mismatched pair is a hard apt failure rather than a stale download.
    my %elsewhere = map { $_ => 1 } qw{
      archive.mariadb.org archive.ubuntu.com keyserver.ubuntu.com localhost
      packages.matrix.org repo.plex.tv repo.powerdns.com security.ubuntu.com
    };

    my @sources;
    File::Find::find(
        sub { push( @sources, $File::Find::name ) if -f $_ },
        "$FindBin::Bin/../templates", "$FindBin::Bin/../scripts",
    );

    my $fetches = qr/(?:curl|wget|git\s+clone|add-apt-repository|apt-add-repository)/;
    my %seen;
    foreach my $file ( sort @sources ) {
        my $text = eval { File::Slurper::read_text($file) };
        next unless defined $text;

        foreach my $line ( split( "\n", $text ) ) {
            next unless $line =~ m/$fetches/;
            while ( $line =~ m{https?://([a-z\d][a-z\d.-]*)}gi ) {
                my $host = lc $1;

                # An address is the guest talking to itself, and a template
                # variable is not a host until it is rendered.
                next if $host =~ m/\A[\d.]+\z/;
                $seen{$host} //= $file =~ s{.*/}{}r;
            }
        }
    }

    ok( scalar keys %seen, 'the sweep found hosts that something fetches' ) or return;

    foreach my $host ( sort keys %seen ) {
        next if $elsewhere{$host};
        ok( $declared{$host}, "$host, fetched in $seen{$host}, is declared in a fetch_hosts" );
    }
};

Test::NoWarnings::had_no_warnings();

done_testing();
