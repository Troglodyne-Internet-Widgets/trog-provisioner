#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";    # stub modules for test-only deps
use Test::More tests => 1;
use Cwd;
use File::Temp qw{tempdir};

my $tmpdir = tempdir( CLEANUP => 1 );

my $ipmap = <<"IPMAP";
[global]
basedir = $tmpdir
admin_user = tester
admin_key = gh:tester
admin_gecos = Test User
admin_email = test\@example.com
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

open my $if, '>', "$tmpdir/ipmap.cfg" or die "Cannot write ipmap: $!";
print $if $ipmap;
close $if;

# recipes.yaml has _base but no 'testdomain' top-level key
open my $rf, '>', "$tmpdir/recipes.yaml" or die "Cannot write recipes: $!";
print $rf <<'RECIPES';
---
_base:
  adminconfig:
    pkgs:
      - vim
RECIPES
close $rf;

# get_recipe_config uses the relative path "recipes.d/" — create it in tmpdir
mkdir "$tmpdir/recipes.d" or die "Cannot mkdir recipes.d: $!";

# Load the script. Use 'do' (not require) so subs are defined.
# Localise @ARGV so the implicit main(@ARGV) at end of script is a no-op.
my $orig_dir = Cwd::getcwd();
{
    local @ARGV;
    do "$FindBin::Bin/../bin/new_config" or die "Could not load new_config: $@";
}

# Temporarily chdir to tmpdir so recipes.d/ is found by get_recipe_config
chdir $tmpdir or die "Cannot chdir: $!";

eval {
    Trog::Provisioner::Config::Generator::main(
        '--ipmap',   "$tmpdir/ipmap.cfg",
        '--recipes', "$tmpdir/recipes.yaml",
        '--skip_ssh',
        'testdomain',
    );
};

chdir $orig_dir;

like(
    $@,
    qr/No recipe configuration.*testdomain/i,
    'dies with helpful message when domain is missing from recipe config',
);
