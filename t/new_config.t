#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal qw{exception};

# Because Config::Simple is incompatible with Test::MockFile
use File::Temp;

# Because this slurps in schema defs
use JSON::Validator::Schema::Troglodyne;

# We have to use any deps of the SUT that actually touch files in BEGIN
use Text::Xslate;
use Config::Simple;


# It is important to use MockFile last
use Test::MockFile();

require_ok( "$FindBin::Bin/../bin/new_config" ) or die "could not require SUT: $@";

my $basedir = '/bogus';

subtest "new_config dies when passed a domain with no configuration" => sub {
    my $ipmap = <<"IPMAP";
[global]
basedir     = $basedir
admin_user  = tester
admin_key   = bogus
admin_gecos = Test User
admin_email = test\@test.test
gateway = 192.168.1.254
resolvers = 8.8.8.8
transfer_user = provision

[ips]
testdomain.test.local = 192.168.1.10
IPMAP

    # recipes.yaml has _base but no 'testdomain.test.local' top-level key
    my $recipe = <<'RECIPES';
---
_base:
  adminconfig:
    pkgs:
      - vim
RECIPES

    # Setup fake files/dirs
    my $td_mock  = Test::MockFile->new_dir($basedir, { mode => 0755 } );
    my $tdd_mock = Test::MockFile->new_dir("$basedir/recipes.d", { mode => 0755 });
    my $recipe_mock = Test::MockFile->file("$basedir/recipes.yaml", $recipe);

    # XXX Config::Simple is not compatible with Test::MockFile due to using bareword filehandles.
    my ( $fh, $ipmap_file ) = File::Temp::tempfile();
    print $fh $ipmap;
    close $fh;
    # However we still have to mock it to prevent explosions in our own code!
    my $ipmap_mock  = Test::MockFile->file($ipmap_file, $ipmap);

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
            '--ipmap',   $ipmap_file,
            '--recipes', "$basedir/recipes.yaml",
            '--skip_ssh',
            'testdomain.test.local',
        )
    };

    like(
        $result,
        qr/No recipe configuration.*testdomain\.test\.local/i,
        'dies with helpful message when domain is missing from recipe config',
    );

};

subtest "a domain with no recipe costs nothing" => sub {
    # auto_assign writes to ipmap.cfg and takes an address out of the pool for
    # good; get_secrets opens the password database and prompts.  Neither
    # should happen on the way to telling somebody they typed the name wrong.
    my $ipmap = <<"IPMAP";
[global]
basedir     = $basedir
admin_user  = tester
admin_key   = bogus
admin_gecos = Test User
admin_email = test\@test.test
gateway = 192.168.1.254
resolvers = 8.8.8.8
transfer_user = provision

[ip_pool]
cidr = 192.168.1.0/30

[ips]
IPMAP

    my $recipe = <<'RECIPES';
---
_base:
  adminconfig:
    pkgs:
      - vim
RECIPES

    my $td_mock     = Test::MockFile->new_dir($basedir, { mode => 0755 } );
    my $tdd_mock    = Test::MockFile->new_dir("$basedir/recipes.d", { mode => 0755 });
    my $recipe_mock = Test::MockFile->file("$basedir/recipes.yaml", $recipe);

    my ( $fh, $ipmap_file ) = File::Temp::tempfile();
    print $fh $ipmap;
    close $fh;
    my $ipmap_mock = Test::MockFile->file($ipmap_file, $ipmap);

    my $before = _slurp($ipmap_file);

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
            '--ipmap',   $ipmap_file,
            '--recipes', "$basedir/recipes.yaml",
            '--skip_ssh',
            'typo.test.local',
        )
    };

    like($result, qr/No recipe configuration/i, 'it says the recipe is missing');
    is(_slurp($ipmap_file), $before,
        'and ipmap.cfg is untouched, so the typo cost no address');
};

# Plain open, not File::Slurper: loading that here would put it in memory ahead
# of Test::MockFile, and anything compiled before the mock is installed opens
# files for real.
sub _slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Could not read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

done_testing();
