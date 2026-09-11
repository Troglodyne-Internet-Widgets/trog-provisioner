#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/new_config.t - bin/new_config, with the filesystem mocked out from under it

=cut

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};

# Because Config::Simple is incompatible with Test::MockFile
use File::Temp;

# None of the three below are called from this file, and all three have to be
# here: anything that opens a file has to be compiled before Test::MockFile
# installs its own open, or it will open the real one at runtime.  Loading them
# is the point, so the unused-import policy has nothing to go on.
## no critic (ProhibitUnusedImports)

# Because this slurps in schema defs
use JSON::Validator::Schema::Troglodyne;

# We have to use any deps of the SUT that actually touch files in BEGIN
use Text::Xslate;
use Config::Simple;

# This one, and not the Trog::Machine that reaches it.  It loads File::HomeDir
# in a BEGIN block, which stats the filesystem looking for xdg-user-dir, and
# compiled after MockFile that is a fatal unmocked stat rather than a lookup
# nobody cares about.
#
# Trog::Machine would fix that too and break something else: it uses
# File::Slurper, so loading it here would compile File::Slurper's opens before
# MockFile could replace them, and every read the SUT does through
# Provisioner::Cookbook would go to the real filesystem and fail on /bogus.
use Net::OpenSSH::More;
## use critic

# It is important to use MockFile last
use Test::MockFile();

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

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
    ## no critic (Plicease::ProhibitLeadingZeros) -- a directory mode, which is octal
    my $td_mock = Test::MockFile->new_dir( $basedir, { mode => 0755 } );
    ## no critic (Plicease::ProhibitLeadingZeros) -- a directory mode, which is octal
    my $tdd_mock    = Test::MockFile->new_dir( "$basedir/recipes.d", { mode => 0755 } );
    my $recipe_mock = Test::MockFile->file( "$basedir/recipes.yaml", $recipe );

    # XXX Config::Simple is not compatible with Test::MockFile due to using bareword filehandles.
    my ( $fh, $ipmap_file ) = File::Temp::tempfile();
    print $fh $ipmap;
    close $fh;

    # However we still have to mock it to prevent explosions in our own code!
    my $ipmap_mock = Test::MockFile->file( $ipmap_file, $ipmap );

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

    ## no critic (Plicease::ProhibitLeadingZeros) -- a directory mode, which is octal

    my $td_mock = Test::MockFile->new_dir( $basedir, { mode => 0755 } );
    ## no critic (Plicease::ProhibitLeadingZeros) -- a directory mode, which is octal
    my $tdd_mock    = Test::MockFile->new_dir( "$basedir/recipes.d", { mode => 0755 } );
    my $recipe_mock = Test::MockFile->file( "$basedir/recipes.yaml", $recipe );

    my ( $fh, $ipmap_file ) = File::Temp::tempfile();
    print $fh $ipmap;
    close $fh;
    my $ipmap_mock = Test::MockFile->file( $ipmap_file, $ipmap );

    my $before = _slurp($ipmap_file);

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
            '--ipmap',   $ipmap_file,
            '--recipes', "$basedir/recipes.yaml",
            '--skip_ssh',
            'typo.test.local',
        )
    };

    like( $result, qr/No recipe configuration/i, 'it says the recipe is missing' );
    is(
        _slurp($ipmap_file), $before,
        'and ipmap.cfg is untouched, so the typo cost no address'
    );
};

# Plain open, not File::Slurper: loading that here would put it in memory ahead
# of Test::MockFile, and anything compiled before the mock is installed opens
# files for real.
sub _slurp {
    my ($path) = @_;
    open( my $fh, '<', $path ) or die "Could not read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

subtest 'a recipe that names rate limits depends on ufw for them' => sub {
    require Provisioner::Recipe::redis;
    require Provisioner::Recipe::ntp;
    require Provisioner::Recipe::plexmediaserver;

    my %prov = ( template_dirs => ['templates'], output_dir => '/tmp', target_packager => 'deb' );

    my $redis = 'Provisioner::Recipe::redis'->new(%prov);
    my %req   = $redis->required_recipes( domain => 'd.test' );
    ok( $req{ufw}, 'redis requires ufw' );
    is_deeply( { $req{ufw}->() }, { rate_limits => { 6379 => 512 } }, 'and hands it the port it listens on' );

    # Most recipes listen on nothing, or reach the network through nginx.
    my $ntp = 'Provisioner::Recipe::ntp'->new(%prov);
    ok( !( $ntp->required_recipes( domain => 'd.test' ) )[0], 'a recipe with no limits requires nothing for them' );

    # plexmediaserver overrides required_recipes, so it has to carry SUPER's
    # wiring as well or its limits are silently dropped.
    my $plex = 'Provisioner::Recipe::plexmediaserver'->new(%prov);
    my %preq = $plex->required_recipes( domain => 'd.test' );
    ok( $preq{letsencrypt}, 'plexmediaserver keeps the dependency it declared' );
    ok( $preq{ufw},         'and gains the one its limits imply' );
};

subtest 'fleet_settings: what every recipe is told about the rest of the fleet' => sub {
    require Provisioner::Recipe::ubuntu;

    my %global = ( domain => 'guest.test.test', ipmap => { 'cache.test.test' => '192.168.1.9' }, cache => 'cache.test.test' );
    Trog::Provisioner::Config::Generator::fleet_settings( 'Provisioner::Recipe::ubuntu', \%global, '192.168.1.254' );

    is( $global{cache_uri}, 'http://192.168.1.9', 'the fetch cache, resolved once for all of them' );
    is( $global{mirror},    q{},                  'a default nobody wrote down is there for every recipe to see' );

    # Config::Simple hands back a string for one value and a list for several.
    is_deeply( $global{resolvers}, ['192.168.1.254'], 'and the resolvers, as a list whichever it was' );

    my %said = ( domain => 'guest.test.test', mirror => 'http://m.test.test/ubuntu' );
    Trog::Provisioner::Config::Generator::fleet_settings( 'Provisioner::Recipe::ubuntu', \%said, [ '192.168.1.254', '1.1.1.1' ] );
    is( $said{mirror},    'http://m.test.test/ubuntu', 'what _global said wins over the default' );
    is( $said{cache_uri}, q{},                         'and no cache configured is none' );
};

# A stand-in for the sftp session, which is the only part of the salvage check
# that has to be a guest.  Two answers are all _salvage_gap asks it for: whether
# what the guest said when asked whether the path still holds anything.
#
# run_sudo's convention, which is the opposite of the usual one: zero means the
# command succeeded.  Here that is `test -n`, so zero means files are there.
{

    package MockGuest;

    sub new { my ( $class, %args ) = @_; return bless {%args}, $class }
    sub run_sudo { my ($self) = @_; return $self->{rc} }
}

# Real directories under here, not mocks.  What the check asks is whether
# anything actually landed on the hypervisor's disk, and answering that against a
# mocked filesystem would only prove the mock agrees with itself.  Strict mode
# has to be told this one tree is allowed, as it is told about ipmap.cfg above.
my $salvage_root = File::Temp::tempdir( CLEANUP => 1 );
Test::MockFile::add_strict_rule_for_filename( [ $salvage_root, qr/^\Q$salvage_root\E/ ] => 1 );

subtest 'a salvage that came back with nothing says so, by name' => sub {
    my $landed = "$salvage_root/landed";
    mkdir $landed                           or die "Could not create $landed: $!";
    open( my $fh, '>', "$landed/dump.rdb" ) or die "Could not write into $landed: $!";
    print $fh "state\n";
    close $fh;

    my $empty = "$salvage_root/empty";
    mkdir $empty or die "Could not create $empty: $!";

    my %args = (
        recipe => 'redis',
        host   => 'd.test.local',
        user   => 'tester',
        remote => '/var/lib/redis',
    );

    # A destination with state in it is a salvage that worked, on this run or on
    # an earlier one.  newer_only means the second run against an unchanged guest
    # copies nothing at all, and that must not read as a failure.
    my $quiet = Trog::Provisioner::Config::Generator::_salvage_gap(
        %args,
        guest       => MockGuest->new( rc => 0 ),
        destination => $landed,
    );
    ok( !$quiet, 'a destination with state in it is not complained about' );

    # Nothing under the path on the guest: either it was never created, or the
    # service has not written into it.  Both are what a first build looks like,
    # and the fetch reads what the service owns now, so neither is unreadable.
    my $absent = Trog::Provisioner::Config::Generator::_salvage_gap(
        %args,
        guest       => MockGuest->new( rc => 1 ),
        destination => $empty,
    );
    ok( $absent,              'a path holding nothing is still reported' );
    ok( !$absent->{alarming}, 'but not as a problem, because that is what a first build looks like' );
    like( $absent->{message}, qr/nothing to salvage/, 'and it says why there was nothing' );

    # The one that matters: the guest has files there and we came away with none.
    my $lost = Trog::Provisioner::Config::Generator::_salvage_gap(
        %args,
        guest       => MockGuest->new( rc => 0 ),
        destination => $empty,
    );
    ok( $lost->{alarming}, 'a path that still holds files but yielded nothing is a problem' );
    like( $lost->{message}, qr/redis/,          'the message names the recipe' );
    like( $lost->{message}, qr{/var/lib/redis}, 'and the path on the guest' );
    like( $lost->{message}, qr/\Q$empty\E/,     'and where the nothing landed' );

    # No longer blamed on permissions.  The fetch runs as root at the far end, so
    # saying the admin user could not read it would send somebody to fix
    # something that is not broken.
    unlike( $lost->{message}, qr/cannot read|unprivileged|no sudo/, 'and does not blame a permission that is no longer the cause' );
    is( $lost->{recipe}, 'redis', 'the recipe comes back out for the summary at the end of the run' );

    # test exits 0 or 1 and nothing else, so anything else is the question not
    # having been asked -- a guest that went away mid-run, or a sudo refused.
    # Filing that as a service which has never run would put the alarm out on
    # state that is still there.
    my $dropped = Trog::Provisioner::Config::Generator::_salvage_gap(
        %args,
        guest       => MockGuest->new( rc => 255 ),
        destination => $empty,
    );
    ok( $dropped->{alarming}, 'a check that could not be run at all stays a problem' );
    like( $dropped->{message}, qr/could not ask/, 'and says that is what happened, rather than guessing' );
};

subtest 'an empty tree of directories is not a salvage' => sub {

    # rget makes the local directories on the way down whether or not it can read
    # what is inside them, so this is exactly what an unreadable fetch leaves.
    my $dir = "$salvage_root/slapd";
    mkdir $dir           or die "Could not create $dir: $!";
    mkdir "$dir/slapd.d" or die "Could not create $dir/slapd.d: $!";

    ok(
        !Trog::Provisioner::Config::Generator::_dir_has_files($dir),
        'directories alone do not count as anything having landed'
    );

    open( my $fh, '>', "$dir/slapd.d/olcDatabase.ldif" ) or die "Could not write into $dir/slapd.d: $!";
    close $fh;

    ok(
        Trog::Provisioner::Config::Generator::_dir_has_files($dir),
        'a file anywhere underneath does'
    );

    ok(
        !Trog::Provisioner::Config::Generator::_dir_has_files("$salvage_root/never-made"),
        'and a destination nothing ever created has nothing in it'
    );

    # A symlink counts as having landed, and is not walked into: one salvaged off
    # a guest can point anywhere, including back at the tree it sits in.
    my $links = "$salvage_root/links";
    mkdir $links                     or die "Could not create $links: $!";
    symlink( $links, "$links/loop" ) or die "Could not symlink into $links: $!";

    ok(
        Trog::Provisioner::Config::Generator::_dir_has_files($links),
        'a symlink is something, and looking at it does not walk into itself'
    );
};

done_testing();
