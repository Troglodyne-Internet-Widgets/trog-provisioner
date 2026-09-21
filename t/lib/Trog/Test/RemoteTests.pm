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
use Trog::Test::RecipeConfig();

my $TLD = 'test.test';

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
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAadminskey someadmin\n" );

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

    my $tmpdir      = File::Temp::tempdir( CLEANUP => 1 );
    my $recipe_file = _configuration( $tmpdir, $recipe );

    # By module name, never by path.  A file required once by path and once by
    # name is compiled twice, and FATAL warnings make the second a death.
    require_ok("Provisioner::Recipe::$recipe");
    my $r = "Provisioner::Recipe::$recipe"->new( output_dir => $tmpdir );

    # t/recipes-remotetests.t checks that there are some, without AUTHOR_TESTING.
    my @tests = $r->tests();

    _generates(
        recipe => $recipe,
        tmpdir => $tmpdir,
        config => $recipe_file,
        tests  => \@tests,
        files  => { $r->template_files() },
    );
    done_testing();
    return;
}

# Writes the recipes.yaml of a run, with a domain for every recipe, and returns
# its path.  Also makes what a recipe reads from the directory of the run.
sub _configuration {
    my ( $tmpdir, $recipe ) = @_;

    mkdir "$tmpdir/$_"           for qw{dotfiles dotfiles/someadmin data domains};
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
    # recipes, and none is the gateway or the .50 that these settings say is us.
    my $pool = join( ' ', map { "192.0.2.$_" } 100 .. 199 );

    my %global = (
        user           => 'test',
        data_source    => "$tmpdir/data",
        install_dir    => "$tmpdir/domains",
        basedir        => "$tmpdir/domains",
        transfer_user  => 'someadmin',
        admin_user     => 'someadmin',
        admin_email    => 'bogus@test.test',
        admin_gecos    => 'Test Test',
        gateway        => '192.0.2.254',
        resolvers      => [qw{192.0.2.254 8.8.8.8 1.1.1.1}],
        bridge_devname => 'ens4',
        dhcp_devname   => 'ens3',
        ip_pool        => { addresses => $pool },
        nameservers    => { ns1       => 'ns1.test.test', ns2 => 'ns2.test.test' },
    );

    # Each domain has its own recipe, and the recipes that `modules` names
    # beside it.  Beside it, not in it: a recipe's configuration takes only its
    # own fields.
    my %required = Trog::Test::RecipeConfig::required_config($tmpdir);
    my %config;
    foreach my $name (@recipes) {
        my %own     = %{ $required{$name}     // {} };
        my @modules = @{ delete $own{modules} // [] };
        $config{"$name.$TLD"} = { $name => \%own, map { $_ => $required{$_} // {} } @modules };

        # Every domain but data answers to data.$TLD as well, which is what the
        # aliases of a real installation look like.
        $config{"$name.$TLD"}{_global} = { aliases => ["data.$TLD"] } unless $name eq 'data';
    }
    $config{_base} = {
        _global   => \%global,
        registrar => $required{registrar},
    };

    my ( $rh, $recipe_file ) = File::Temp::tempfile( DIR => $tmpdir );
    print {$rh} YAML::XS::Dump( \%config );
    close($rh) or die "Could not close $recipe_file: $!";

    return $recipe_file;
}

# Runs new_config for the domain of the recipe, and checks what it wrote.
sub _generates {
    my (%args) = @_;
    my ( $recipe, $tmpdir, $tests, $files ) = @args{qw{recipe tmpdir tests files}};

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
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
