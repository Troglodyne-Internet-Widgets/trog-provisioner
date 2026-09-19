package Trog::Test::RemoteTests;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

Trog::Test::RemoteTests - generate one recipe's domain, and check that it has its
guest tests

=head1 SYNOPSIS

In F<t/remotetests-ntp.t>:

    use FindBin::libs;
    use Trog::Test::RemoteTests();
    Trog::Test::RemoteTests::run('ntp');

=head1 DESCRIPTION

Each recipe has a test of its own in F<t/remotetests-$recipe.t>, and each one
calls C<run> with its recipe.  So the pre-commit hook, which runs the tests that
a change can break, runs the one for the recipe that changed, and not all of
them.  F<t/recipes-remotetests.t> checks that every recipe has one.

C<run> writes a configuration for a domain for every recipe, the way an
installation has many, and runs F<bin/new_config> for the domain of C<$recipe>
only.  Then it checks that the configuration package has what F<bin/provision>
needs, every file that C<template_files> names, and every guest test that
C<tests> names.  It does not provision a guest.  The hypervisor is mocked,
because the recipe is what is under test.

It skips unless C<AUTHOR_TESTING> is set.

=cut

# Never the installation's real /etc/trog-provisioner: what these assert on
# must not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- every test that uses this reads it after BEGIN returns, which local would undo

use FindBin;
use File::Copy();
use File::Slurper::Temp();
use File::Temp();
use File::Touch();
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use Test::More;
use YAML::XS();

use Provisioner::Cookbook();
use Provisioner::Utils();

my $TLD = 'test.test';

# What each recipe must be given, where it has no default that could mean
# anything.  `modules` names the recipes that go beside it in its domain, each
# with the configuration that it has here.  $tmpdir is the directory of the run.
sub _required_config {
    my ($tmpdir) = @_;

    return (

        # A mirror of no release, and a shipper with nowhere to ship.  The same
        # minimum t/recipes.t gives them.
        aptmirror  => { releases => ['noble'] },
        logshipper => { host     => 'logs.test.test' },

        # Both of these are full releases on purpose.  The archives they come
        # from publish one artifact per release, so a series like 7.1.0 or 10.11
        # is a 404 that the recipe cannot do anything useful with.
        imagemagick => { version => '7.1.0-48' },
        mariadb     => {
            root_pw  => 's3cr3t',
            dumpfile => 'dump.sql',
            version  => '10.11.6',
        },

        # A password is not a thing a schema can default, and grubconf refuses
        # to render nothing.  The same minimum t/recipes.t gives them.
        grafana       => { admin_password => 's3cr3t' },
        grafanasyslog => { modules        => ['grafana'] },
        grubconf      => { grub_vars      => { GRUB_TIMEOUT => '5', GRUB_CMDLINE_LINUX => 'net.ifnames=0' } },

        tpsgi       => { routers => ['app.psgi'] },
        adminconfig => { skel    => "$tmpdir/dotfiles" },
        admincode   => {
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
            targets     => { etc => '/etc' },
            key_file    => 'backup.rsa',
            data_source => "$tmpdir/data",
        },
        postgres        => { dumps => [] },
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
        ldap => { admin_password => 'bogus' },
        sssd => {
            base_dn  => 'bogus',
            ldap_uri => 'ldap://test.test',
        },
    );
}

=head1 FUNCTIONS

=head2 @recipes = recipes()

The recipes that have a test of their own: C<data>, and every recipe that
L<Provisioner::Cookbook> names except C<registrar>.  registrar is the
credentials for a zone that somebody else holds, and installs nothing to test.

=cut

sub recipes {
    return ( 'data', grep { $_ ne 'data' && $_ ne 'registrar' } Provisioner::Cookbook->names() );
}

=head2 run($recipe)

Generates the domain of C<$recipe>, checks what it generated, and ends the test
with C<done_testing>.  It skips the whole test unless C<AUTHOR_TESTING> is set.

=cut

sub run {
    my ($recipe) = @_;

    plan skip_all => 'Test must be run under AUTHOR_TESTING' unless $ENV{AUTHOR_TESTING};

    # The administrator's keys are read out of the configuration directory,
    # rather than named as an identity for cloud-init to fetch at first boot.
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAdogeskey doge\n" );

    require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

    # What this is about is the recipe: that it renders, and that the generator
    # writes out what the recipe says it does.  The hypervisor is not part of
    # that, so the two facts that the generator wants from it are answered here.
    # Trog::HV requires its backend lazily, so it is loaded for the mock to
    # attach to.
    require Trog::HV;
    require Trog::HV::Libvirt;
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( virbr_ip  => sub { '192.168.122.1' } );
    $hv_mock->redefine( sshd_port => sub { 22 } );

    # garage, matrix and trogrunner each keep a file for the guest in the secret
    # store, so new_config opens it.  That needs a store, and its password handed
    # in up front, as Trog::Credentials documents for a run with nobody at a
    # keyboard.  Both are throwaways in this test's own configuration directory.
    require Trog::Config;
    require Trog::Credentials;
    require Trog::Secrets;
    Trog::Secrets->create( Trog::Config->path('secrets.kdbx'), 'throwaway', 'secret:seed/entry/password' => 'throwaway' );
    Trog::Credentials->remember( keepass => 'throwaway' );

    my $tmpdir = File::Temp::tempdir( CLEANUP => 1 );
    my ( $ipmap_file, $recipe_file ) = _configuration( $tmpdir, $recipe );

    # By module name, never by path.  A file required once by path and once by
    # name is compiled twice, and FATAL warnings make the second a death.
    require_ok("Provisioner::Recipe::$recipe");
    my $r = "Provisioner::Recipe::$recipe"->new( output_dir => $tmpdir );

    # t/recipes-remotetests.t checks that there are some, without AUTHOR_TESTING.
    my @tests = $r->tests();

    _generates(
        recipe => $recipe,
        tmpdir => $tmpdir,
        ipmap  => $ipmap_file,
        config => $recipe_file,
        tests  => \@tests,
        files  => { $r->template_files() },
    );
    done_testing();
    return;
}

# Writes the ipmap.cfg and recipes.yaml of a run, with a domain for every
# recipe, and returns their paths.  Also makes what a recipe reads from the
# directory of the run.
sub _configuration {
    my ( $tmpdir, $recipe ) = @_;

    mkdir "$tmpdir/$_"           for qw{dotfiles dotfiles/doge data domains};
    mkdir "$tmpdir/data/$_.$TLD" for qw{data backup backupdestination};
    File::Touch::touch("$tmpdir/dotfiles/test");

    # The backup recipes read a key from the data directory, and making one
    # takes time that no other recipe needs to spend.
    if ( $recipe =~ m{\Abackup} ) {
        Provisioner::Utils::write_ssh_keypair( "$tmpdir/data/backup.$TLD/backup.rsa", RSA => 2048, 'Trog::Test::RemoteTests' );
        File::Copy::copy( "$tmpdir/data/backup.$TLD/backup.rsa", "$tmpdir/data/backupdestination.$TLD/backup.rsa" ) or die "Could not copy the backup key: $!";
    }

    my @recipes = recipes();

    # One address per domain out of the pool.  A hundred is more than there are
    # recipes, and none is the gateway or the .50 that this ipmap says is us.
    my $pool    = join( ' ', map { "192.168.1.$_" } 100 .. 199 );
    my $aliases = join( '',  map { "$_.$TLD=data.$TLD\n" } grep { $_ ne 'data' } @recipes );
    my $ipmap   = <<"IPMAP";
[global]
ip=192.168.1.50
basedir=$tmpdir/domains
transfer_user=doge
admin_user=doge
admin_email=bogus\@test.test
admin_gecos=Test Test
gateway=192.168.1.254
resolvers=192.168.1.254, 8.8.8.8, 1.1.1.1
bridge_devname=ens4
dhcp_devname=ens3
[ip_pool]
addresses=$pool

[aliases]
$aliases
[nameservers]
ns1=ns1.test.test
ns2=ns2.test.test
IPMAP

    # Each domain has its own recipe, and the recipes that `modules` names
    # beside it.  Beside it, not in it: a recipe's configuration takes only its
    # own fields.
    my %required = _required_config($tmpdir);
    my %config;
    foreach my $name (@recipes) {
        my %own     = %{ $required{$name}     // {} };
        my @modules = @{ delete $own{modules} // [] };
        $config{"$name.$TLD"} = { $name => \%own, map { $_ => $required{$_} // {} } @modules };
    }
    $config{_base} = {
        _global   => { user => 'test', data_source => "$tmpdir/data", install_dir => "$tmpdir/domains" },
        registrar => {
            type => 'bogus',
            user => 'bogus',
            key  => 'bogus',
        },
    };

    my ( $ih, $ipmap_file ) = File::Temp::tempfile( DIR => $tmpdir );
    print {$ih} $ipmap;
    close($ih) or die "Could not close $ipmap_file: $!";

    my ( $rh, $recipe_file ) = File::Temp::tempfile( DIR => $tmpdir );
    print {$rh} YAML::XS::Dump( \%config );
    close($rh) or die "Could not close $recipe_file: $!";

    return ( $ipmap_file, $recipe_file );
}

# Runs new_config for the domain of the recipe, and checks what it wrote.
sub _generates {
    my (%args) = @_;
    my ( $recipe, $tmpdir, $tests, $files ) = @args{qw{recipe tmpdir tests files}};

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
            '--ipmap',   $args{ipmap},
            '--recipes', $args{config},
            '--skip_ssh',
            "$recipe.$TLD",
        )
    };
    is( $result, undef, 'new_config ran without issue' );

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- each is a file that this run just made, in a directory that nothing else can see
    my $ddir = "$tmpdir/domains/$recipe.$TLD";
    ok( -f "$ddir/$_", "$_ generated" )            for qw{Makefile data.tar.gz provision.conf users.yaml};
    ok( -f "$ddir/$_", "$_ generated in datadir" ) for values %$files;

    foreach my $test (@$tests) {
        my $tname = $test =~ s/tt\z/t/r;
        ok( -f "$ddir/t/$tname", "test generated in $ddir/t/$tname" );
    }
    ## use critic
    return;
}

1;
