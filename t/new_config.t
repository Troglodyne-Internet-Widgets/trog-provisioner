#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use FindBin::libs;

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
tld = test.local
ip = 192.168.1.1
gateway = 192.168.1.254
resolvers = 8.8.8.8
bridge_devname = virbr0
dhcp_devname = eth0
transfer_user = provision

[ips]
testdomain = 192.168.1.10
IPMAP

    # recipes.yaml has _base but no 'testdomain' top-level key
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
            'testdomain',
        )
    };

    like(
        $result,
        qr/No recipe configuration.*testdomain/i,
        'dies with helpful message when domain is missing from recipe config',
    );

};

done_testing();
