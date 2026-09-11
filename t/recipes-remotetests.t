use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/recipes-remotetests.t - the recipes, against a real guest (AUTHOR_TESTING only)

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
use Provisioner::Cookbook();
use YAML::XS();
use File::Temp qw{tempdir tempfile};
use File::Touch;
use File::Copy;

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};

if ( !$ENV{AUTHOR_TESTING} ) {
    plan skip_all => 'Test must be run under AUTHOR_TESTING';
}

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

# What this file is about is the recipes: that each renders, and that the
# generator writes out what the recipe said it would.  The hypervisor is not
# part of that, and asking a real one means this only runs on a machine that
# happens to be one -- so the two facts the generator wants off it are answered
# here instead.
require Trog::HV;
my $hv_mock = Test::MockModule->new('Trog::HV');
$hv_mock->redefine( virbr_ip  => sub { '192.168.122.1' } );
$hv_mock->redefine( sshd_port => sub { 22 } );

# garage, matrix and trogrunner each keep a file for the guest in the secret
# store, so new_config opens the store to put it there.  That needs a store to
# open, and its password handed in up front -- the way Trog::Credentials
# documents for a run with nobody at a keyboard, since the answer to a prompt
# here is undef and the run dies.  Both are throwaways in this test's own
# configuration directory, built the way t/new_config-secrets.t builds one.
require Trog::Config;
require Trog::Credentials;
require Trog::Secrets;
Trog::Secrets->write( Trog::Config->path('secrets.kdbx'), 'throwaway', 'secret:seed/entry/password' => 'throwaway' );
Trog::Credentials->remember( keepass => 'throwaway' );

# Every recipe there is, by the name the configuration uses.  The Cookbook's
# answer rather than a walk of the directory, which also found each distro
# subclass under Ubuntu/ and so tested most recipes twice.  data is tested
# first, on its own, below.
my @available = grep { $_ ne 'data' } Provisioner::Cookbook->names();

my $tld     = 'test.test';
my $aliases = join( ".$tld=data.$tld\n", @available ) . ".$tld=data.$tld";

# One address per recipe, each its own domain, out of the pool -- which is where
# addresses have come from since ips.db.  The [ips] section this used to write,
# handing every recipe the same address, is not read by anything any more.  A
# hundred is more than there are recipes, and none is the gateway or the .50
# this ipmap says is us.
my $pool = join( ' ', map { "192.168.1.$_" } 100 .. 199 );

# Populate stuff needed by recipes
my $tmpdir = tempdir( CLEANUP => 1 );
mkdir "$tmpdir/dotfiles";
mkdir "$tmpdir/dotfiles/doge";
mkdir "$tmpdir/data";
mkdir "$tmpdir/data/data.test.test";
mkdir "$tmpdir/domains";
mkdir "$tmpdir/data/backup.test.test";
mkdir "$tmpdir/data/backupdestination.test.test";
Provisioner::Utils::write_ssh_keypair( "$tmpdir/data/backup.test.test/backup.rsa", RSA => 2048, 'recipes-remotetests.t' );
die "Could not create backup.rsa: $@ $?" unless -f "$tmpdir/data/backup.test.test/backup.rsa";
File::Copy::copy( "$tmpdir/data/backup.test.test/backup.rsa", "$tmpdir/data/backupdestination.test.test/backup.rsa" );
File::Touch::touch("$tmpdir/dotfiles/test");

# Build the config to pass to tools
my $ipmap = "[global]
ip=192.168.1.50
basedir=$tmpdir/domains
transfer_user=doge
admin_user=doge
admin_key=gh:teodesian
admin_email=bogus\@test.test
admin_gecos=Test Test
gateway=192.168.1.254
resolvers=127.0.0.1, 192.168.1.254, 8.8.8.8, 1.1.1.1
bridge_devname=ens4
dhcp_devname=ens3
[ip_pool]
addresses=$pool

[aliases]
$aliases
[nameservers]
ns1=ns1.test.test
ns2=ns2.test.test";

#XXX hate having to hardcode this, should really make this a toplevel thing in recipes
my %recipes_raw = (

    # Required, and neither has a default that could mean anything: a mirror of
    # no release, and a shipper with nowhere to ship.  The same minimum
    # t/recipes.t gives them.
    aptmirror  => { releases => ['noble'] },
    logshipper => { host     => 'logs.test.test' },

    # Both of these are full releases on purpose.  The archives they come from
    # publish one artifact per release, so a series like 7.1.0 or 10.11 is a
    # 404 the recipe cannot do anything useful with -- which is why both
    # recipes now insist on the whole version, and why these fixtures have to
    # look like the real thing.
    imagemagick => { version => '7.1.0-48' },
    mariadb     => {
        root_pw  => 's3cr3t',
        dumpfile => 'dump.sql',
        version  => '10.11.6',
    },
    tpsgi       => { routers  => ['app.psgi'] },
    tcms        => { tcms_dir => 'tcms' },
    adminconfig => {
        skel => "/$tmpdir/dotfiles",
    },
    admincode => {
        repos_from => [],
        basedir    => 'Code',
    },
    nginxproxy => {
        vhosts => {
            8080 => {
                proxy_uri  => 'run/app.sock',
                static_dir => 'www/static',
            }
        }
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
        key_file    => 'backup.rsa',
        data_source => "$tmpdir/data",
    },
    backup => {
        modules     => [],
        targets     => { etc => '/etc' },
        key_file    => 'backup.rsa',
        data_source => "$tmpdir/data",
    },
    postgres => {
        dumps => [],
    },
    plexmediaserver => {
        plex_login_name => 'bogus',
        admin_mail      => 'bogus@test.test',
    },
    gogs => {
        version        => 'bogus',
        admin_password => 'bogus',
    },
    openvpnclient => {
        server   => 'bogus.test',
        cert_dir => '/bogus',
    },
    ldap => {
        admin_password => 'bogus',
    },
    sssd => {
        base_dn  => 'bogus',
        ldap_uri => 'ldap://test.test',
    },
);

# Make each so-named domain to provision do nothing but provision its own stuff
foreach my $key ( 'data', @available ) {

    # XXX ALSO re-do things such that recipes can inform their dependent recipes of what their required values are gonna be
    if ( ref $recipes_raw{$key}{modules} eq 'ARRAY' ) {
        my $modules = delete $recipes_raw{$key}{modules};
        foreach my $module (@$modules) {
            $recipes_raw{$key}{$module} = $recipes_raw{$module} // {};
        }
    }
}
foreach my $key ( 'data', @available ) {
    my $data = delete $recipes_raw{$key} // {};

    # The domain is fully qualified; the recipe inside it is still the recipe.
    $recipes_raw{"$key.$tld"} = { $key => $data };
}
$recipes_raw{_base} = {
    _global => {
        user      => 'test',
        registrar => {
            type => "bogus",
            user => "bogus",
            key  => "bogus",
        },
    },
    data => { from => "/$tmpdir/data", to => "/$tmpdir/domains" },
};

my $recipes = YAML::XS::Dump( \%recipes_raw );

my ( $ih, $ipmap_file ) = tempfile();
print $ih $ipmap;
close $ih;

my ( $rh, $recipe_file ) = tempfile();
print $rh $recipes;
close $rh;

# First make sure this recpie actually has tests to run on the remote
test_recipe('data');
foreach my $recipe (@available) {
    test_recipe($recipe);
}

done_testing();

sub test_recipe {
    my $recipe = shift;

    # By module name, never by path.  A file required once by path and once by
    # name is compiled twice -- and data.pm is reached by name as soon as
    # new_config loads Provisioner::Recipe::Ubuntu::data, whose use parent
    # names it -- so its second compile redefined every sub in it, which FATAL
    # warnings make a death.
    require_ok("Provisioner::Recipe::$recipe");

    my %opt = (

        # Some recipes like ufw use this
        output_dir => $tmpdir,
    );

    no strict 'refs';
    my $r = "Provisioner::Recipe::$recipe"->new(%opt);

    my @tests = $r->tests();
    ok( @tests, "$recipe recipe Has tests" );

    my %files = $r->template_files();

    do_provision( $recipe, $ipmap_file, $recipe_file, \@tests, %files );

    # TODO Actually run trog-provisioner.

    #TODO re-run generator and make sure everything in remote_files was backed up, and that we do have remote_files

}

sub do_provision {
    my ( $recipe, $ipmap_file, $recipe_file, $tests, %files ) = @_;

    my $provisioner_bin = '/opt/trog-provisioner/bin/provision';

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
            '--ipmap',   $ipmap_file,
            '--recipes', $recipe_file,
            '--skip_ssh',
            "$recipe.test.test",
        )
    };
    is( $result, undef, "new_config ran without issue" );
    my $ddir = "$tmpdir/domains/$recipe.test.test";
    ok( -f "$ddir/Makefile",       "Makefile generated" );
    ok( -f "$ddir/data.tar.gz",    "data.tar.gz generated" );
    ok( -f "$ddir/provision.conf", "provision.conf generated" );
    ok( -f "$ddir/users.yaml",     "users.yaml generated" );
    foreach my $file ( values(%files) ) {
        ok( -f "$ddir/$file", "$file generated in datadir" );
    }

    foreach my $test (@$tests) {
        my $tname = $test;
        $tname =~ s/tt$/t/;
        ok( -f "$ddir/t/$tname", "test generated in $ddir/t/$tname" ) or die "nothing generated in $ddir";
    }
}
