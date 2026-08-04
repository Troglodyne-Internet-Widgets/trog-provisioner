use strict;
use warnings;

use FindBin;
use FindBin::libs;
use YAML;
use File::Find;
use File::Temp qw{tempdir tempfile};
use File::Touch;
use File::Copy;

use Test::More;
use Test::Fatal qw{exception};

if (!$ENV{AUTHOR_TESTING}) {
    plan skip_all => 'Test must be run under AUTHOR_TESTING';
}

require_ok( "$FindBin::Bin/../bin/new_config" ) or die "could not require SUT: $@";

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
"$FindBin::Bin/../lib/Provisioner/Recipe/");

# Treat 'data' as special
@available = grep { $_ ne 'data' } @available;

#XXX hardcoded
my $test_ip = '192.168.1.40';

my $aliases = join("=data\n", @available).'=data';
my $ips = join("=$test_ip\n", @available)."=$test_ip";

# Populate stuff needed by recipes
my $tmpdir = tempdir( CLEANUP => 1 );
mkdir "$tmpdir/dotfiles";
mkdir "$tmpdir/dotfiles/doge";
mkdir "$tmpdir/data";
mkdir "$tmpdir/data/data.test.test";
mkdir "$tmpdir/domains";
mkdir "$tmpdir/data/backup.test.test";
mkdir "$tmpdir/data/backupdestination.test.test";
system( 'ssh-keygen', '-t', 'rsa', '-b', '2048', '-f', "$tmpdir/data/backup.test.test/backup.rsa", '-N', '', '-q' );
die "Could not create backup.rsa: $@ $?" unless -f "$tmpdir/data/backup.test.test/backup.rsa";
File::Copy::copy("$tmpdir/data/backup.test.test/backup.rsa", "$tmpdir/data/backupdestination.test.test/backup.rsa");
File::Touch::touch("$tmpdir/dotfiles/test");

# Build the config to pass to tools
    my $ipmap = "[global]
tld=test.test
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
addresses=
cidr=
[ips]
data=$test_ip
$ips
[aliases]
$aliases
[nameservers]
ns1=ns1.test.test
ns2=ns2.test.test";

#XXX hate having to hardcode this, should really make this a toplevel thing in recipes
my %recipes_raw = (
    imagemagick =>  { version => '7.1.0' },
    mariadb => {
        root_pw  => 's3cr3t',
        dumpfile => 'dump.sql',
        version  => '10.11',
    },
    tpsgi => { routers => ['app.psgi'] },
    tcms =>  { tcms_dir => 'tcms' },
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
        admin_mail => 'bogus@test.test',
    },
    gogs => {
        version => 'bogus',
        admin_password => 'bogus',
        nginxproxy => {
            vhosts => {
                8080 => {
                    proxy_uri => '/bogus/bogus',
                    static_dir => '/bogus/bogus',
                },
            },
        },
    },
    deluged => {
        nginxproxy => {
            vhosts => {
                8080 => {
                    proxy_uri => '/bogus/bogus',
                    static_dir => '/bogus/bogus',
                },
            },
        },
    },
    openvpnclient => {
        server => 'bogus.test',
        cert_dir => '/bogus',
    },
);
# Make each so-named domain to provision do nothing but provision its own stuff
foreach my $key ('data', @available) {
    # XXX standardize required_modules instead in recipes
    # XXX ALSO re-do things such that recipes can inform their dependent recipes of what their required values are gonna be
    if (ref $recipes_raw{$key}{modules} eq 'ARRAY') {
        my $modules = delete $recipes_raw{$key}{modules};
        foreach my $module (@$modules) {
            $recipes_raw{$key}{$module} = $recipes_raw{$module} // {};
        }
    }
}
foreach my $key ('data', @available) {
    my $data = $recipes_raw{$key} // {};
    $recipes_raw{$key} = { $key => $data };
}
$recipes_raw{_base} = {
    _global => {
        user => 'test',
        registrar => {
            type => "bogus",
            user => "bogus",
            key  => "bogus",
        }
    },
    data => { from => "/$tmpdir/data", to => "/$tmpdir/domains" },
};

my $recipes = YAML::Dump(\%recipes_raw);

my ($ih, $ipmap_file)  = tempfile();
print $ih $ipmap;
close $ih;

my ($rh, $recipe_file) = tempfile();
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
    require_ok( "$FindBin::Bin/../lib/Provisioner/Recipe/$recipe.pm" );
    no strict 'refs';
    my $r = "Provisioner::Recipe::$recipe"->new();
    use strict;

    my @tests = $r->tests();
    ok(@tests, "$recipe recipe Has tests");

    my %files = $r->template_files();

    do_provision($recipe, $ipmap_file, $recipe_file, \@tests, %files);

    # TODO Actually run trog-provisioner.

    #TODO re-run generator and make sure everything in remote_files was backed up, and that we do have remote_files

}

sub do_provision {
    my ($recipe, $ipmap_file, $recipe_file, $tests, %files) = @_;

    my $provisioner_bin = '/opt/trog-provisioner/bin/provision';

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
            '--ipmap',   $ipmap_file,
            '--recipes', $recipe_file,
            '--skip_ssh',
            $recipe,
        )
    };
    is($result, undef, "new_config ran without issue");
    my $ddir = "$tmpdir/domains/$recipe.test.test";
    ok(-f "$ddir/Makefile", "Makefile generated");
    ok(-f "$ddir/data.tar.gz", "data.tar.gz generated");
    ok(-f "$ddir/provision.conf", "provision.conf generated");
    ok(-f "$ddir/users.yaml", "users.yaml generated");
    foreach my $file (values(%files)) {
        ok(-f "$ddir/$file", "$file generated in datadir");
    }

    foreach my $test (@$tests) {
        my $tname = $test;
        $tname =~ s/tt$/t/;
        ok( -f "$ddir/t/$tname", "test generated in $ddir/t/$tname") or die qx{ls $ddir};
    }
}
