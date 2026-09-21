#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/new_config.t - bin/new_config, with the filesystem mocked out from under it

=cut

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

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

    # recipes.yaml has _base but no 'testdomain.test.local' top-level key
    my $recipe = <<"RECIPES";
---
_base:
  _global:
    basedir: $basedir
    admin_user: tester
    admin_gecos: Test User
    admin_email: test\@test.test
    gateway: 192.0.2.254
    resolvers: [8.8.8.8]
    transfer_user: provision
  adminconfig:
    pkgs:
      - vim
RECIPES

    # Setup fake files/dirs
    my $td_mock     = Test::MockFile->new_dir( $basedir,             { mode => 0755 } );
    my $tdd_mock    = Test::MockFile->new_dir( "$basedir/recipes.d", { mode => 0755 } );
    my $recipe_mock = Test::MockFile->file( "$basedir/recipes.yaml", $recipe );

    # Read out of the configuration directory rather than fetched by cloud-init,
    # and MockFile is strict here: an unmocked read is fatal, not a miss.  The
    # path is the one Trog::Config resolves, which is the environment override
    # this file sets in BEGIN rather than the basedir the rest of these mock.
    my $keys_mock = Test::MockFile->file( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtesterskey tester\n" );

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
            '--recipes', "$basedir/recipes.yaml",
            '--skip_ssh',
            'testdomain.test.local',
        )
    };

    like(
        $result,
        qr/No[ ]recipe[ ]configuration\N*testdomain\.test\.local/i,
        'dies with helpful message when domain is missing from recipe config',
    );

};

# Loopback answers on a guest running its own DNS and nowhere else.  Named for
# the installation it reaches every guest, most of which have nothing listening
# there -- which is what had the fetch cache stripping it back out of the list
# it hands nginx, and every few lookups was a refused connection.
#
subtest 'an installation that names loopback as a resolver is refused' => sub {

    # Its own directory, because Provisioner::Cookbook keeps one configuration
    # per path and the subtest above has already read the one at $basedir.
    my $loopdir = '/bogus-loopback';

    my $recipe = <<"RECIPES";
---
_base:
  _global:
    basedir: $loopdir
    admin_user: tester
    admin_gecos: Test User
    admin_email: test\@test.test
    gateway: 192.0.2.254
    resolvers: [127.0.0.1, 192.0.2.254]
    transfer_user: provision
  adminconfig:
    pkgs:
      - vim
testdomain.test.local:
  adminconfig: {}
RECIPES

    my $td_mock     = Test::MockFile->new_dir( $loopdir,             { mode => 0755 } );
    my $tdd_mock    = Test::MockFile->new_dir( "$loopdir/recipes.d", { mode => 0755 } );
    my $recipe_mock = Test::MockFile->file( "$loopdir/recipes.yaml", $recipe );

    my $keys_mock = Test::MockFile->file( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtesterskey tester\n" );

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
            '--recipes', "$loopdir/recipes.yaml",
            '--skip_ssh',
            'testdomain.test.local',
        )
    };

    like( $result, qr/127[.]0[.]0[.]1/,                 'the refusal names the address' );
    like( $result, qr/runs[ ]its[ ]own[ ]DNS[ ]server/, 'and says where it would answer' );
    like( $result, qr/nostubresolver/,                  'and which recipe puts it in front for such a guest' );
};

subtest "a domain with no recipe costs nothing" => sub {

    # auto_assign takes an address out of the pool for good, and get_secrets
    # opens the password database and prompts.  Neither should happen on the
    # way to telling somebody they typed the name wrong.
    my $recipe = <<"RECIPES";
---
_base:
  _global:
    basedir: $basedir
    admin_user: tester
    admin_gecos: Test User
    admin_email: test\@test.test
    gateway: 192.0.2.254
    resolvers: [8.8.8.8]
    transfer_user: provision
    ip_pool:
      cidr: 192.0.2.0/30
  adminconfig:
    pkgs:
      - vim
RECIPES

    my $td_mock     = Test::MockFile->new_dir( $basedir,             { mode => 0755 } );
    my $tdd_mock    = Test::MockFile->new_dir( "$basedir/recipes.d", { mode => 0755 } );
    my $recipe_mock = Test::MockFile->file( "$basedir/recipes.yaml", $recipe );

    # Read out of the configuration directory rather than fetched by cloud-init,
    # and MockFile is strict here: an unmocked read is fatal, not a miss.  The
    # path is the one Trog::Config resolves, which is the environment override
    # this file sets in BEGIN rather than the basedir the rest of these mock.
    my $keys_mock = Test::MockFile->file( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtesterskey tester\n" );

    my $before = _slurp("$basedir/recipes.yaml");

    my $result = exception {
        Trog::Provisioner::Config::Generator::main(
            '--recipes', "$basedir/recipes.yaml",
            '--skip_ssh',
            'typo.test.local',
        )
    };

    like( $result, qr/No[ ]recipe[ ]configuration/i, 'it says the recipe is missing' );
    is(
        _slurp("$basedir/recipes.yaml"), $before,
        'and recipes.yaml is untouched, so the typo cost no address'
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
    close($fh) or die "Could not close $path: $!";
    return $content;
}

subtest 'a recipe that names rate limits depends on ufw for them' => sub {
    require Provisioner::Recipe::redis;
    require Provisioner::Recipe::tmpfs;
    require Provisioner::Recipe::plexmediaserver;

    my %prov = ( template_dirs => ['templates'], output_dir => '/tmp', target_packager => 'deb' );

    my $redis = 'Provisioner::Recipe::redis'->new(%prov);
    my %req   = $redis->required_recipes( domain => 'd.test' );
    ok( $req{ufw}, 'redis requires ufw' );
    is_deeply( { $req{ufw}->() }, { rate_limits => { 6379 => 512 }, listeners => { 6379 => { redis => 1 } } }, 'and hands it the port it listens on, with its claim to it' );

    # Most recipes listen on nothing, or reach the network through nginx.
    my $tmpfs = 'Provisioner::Recipe::tmpfs'->new(%prov);
    ok( !( $tmpfs->required_recipes( domain => 'd.test' ) )[0], 'a recipe that binds no port requires nothing for it' );

    # plexmediaserver overrides required_recipes, so it has to carry SUPER's
    # wiring as well or its limits are silently dropped.
    my $plex = 'Provisioner::Recipe::plexmediaserver'->new(%prov);
    my %preq = $plex->required_recipes( domain => 'd.test' );
    ok( $preq{letsencrypt}, 'plexmediaserver keeps the dependency it declared' );
    ok( $preq{ufw},         'and gains the one its limits imply' );
};

subtest 'apply_global_defaults: every recipe sees the distribution defaults' => sub {
    require Provisioner::Recipe::ubuntu;

    my %global = ( domain => 'guest.test.test' );
    Trog::Provisioner::Config::Generator::apply_global_defaults( 'Provisioner::Recipe::ubuntu', \%global );
    is( $global{mirror}, q{}, 'a default nobody wrote down is there for every recipe to see' );

    my %said = ( domain => 'guest.test.test', mirror => 'http://m.test.test/ubuntu' );
    Trog::Provisioner::Config::Generator::apply_global_defaults( 'Provisioner::Recipe::ubuntu', \%said );
    is( $said{mirror}, 'http://m.test.test/ubuntu', 'what _global said wins over the default' );
};

# Provisioner::Cookbook::has stats a recipe's .pm to answer whether there is one,
# and the subtest below asks it about vm.  Allowed the way $salvage_root is
# below: strict mode has to be told which real trees an assertion needs.
#
# By suffix rather than by path, because the stat is against the canonical path
# perl resolved the require to while FindBin gives $Bin/../lib -- and
# normalising that would mean statting it.
Test::MockFile::add_strict_rule_for_filename( [qr{/lib/Provisioner/Recipe/}] => 1 );

# Which of the vm recipe's fields _global may pass through into provision.conf.
# Read off the schema rather than listed here, so a computed field added to that
# recipe cannot start being offered without this noticing.
subtest 'hv_settings offers the machine knobs, not the facts about the machine' => sub {
    my %settings = map { $_ => 1 } Trog::Provisioner::Config::Generator::hv_settings();

    ok( $settings{disk_cache}, 'a knob an operator may set is passed through' );
    ok( $settings{cpu_mode},   'and so is the CPU model' );

    my $props    = Provisioner::Cookbook->properties( { Provisioner::Cookbook->spec('vm') } );
    my @readonly = sort grep { $props->{$_}{readOnly} } keys %$props;
    ok( scalar @readonly, 'the vm recipe declares fields it answers for itself' ) or return;

    # Naming one of these in _global would write it into provision.conf and point
    # the domain XML at a volume, or a MAC, that nobody created.
    my @offered = grep { $settings{$_} } @readonly;
    is( "@offered", q{}, 'and none of those can be named in _global' );
};

# A setting of 0 is an answer, and the vm recipe reads disk_iothreads=0 as "no
# iothreads".  An empty one is not: Config::Simple reads a bare `key=` that way.
subtest 'hv_lines passes a setting of 0 through, and leaves out an empty one' => sub {
    my $lines = Trog::Provisioner::Config::Generator::hv_lines( { disk_iothreads => 0, disk_cache => q{}, disk_queues => undef, cpu_mode => 'host-passthrough' }, { cpu_mode => 1 } );

    like( $lines, qr/^disk_iothreads=0$/m, 'a 0 is written' );
    unlike( $lines, qr/disk_cache|disk_queues/, 'an empty or absent setting is not' );
    unlike( $lines, qr/cpu_mode/,               'and neither is one already written above' );
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
# has to be told this one tree is allowed, as it is told about the others above.
my $salvage_root = File::Temp::tempdir( CLEANUP => 1 );
Test::MockFile::add_strict_rule_for_filename( [ $salvage_root, qr/^\Q$salvage_root\E/ ] => 1 );

subtest 'a salvage that came back with nothing says so, by name' => sub {
    my $landed = "$salvage_root/landed";
    mkdir $landed                           or die "Could not create $landed: $!";
    open( my $fh, '>', "$landed/dump.rdb" ) or die "Could not write into $landed: $!";
    print {$fh} "state\n";
    close($fh) or die "Could not close $landed/dump.rdb: $!";

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
    my $quiet = Trog::Provisioner::Config::Generator::_salvage_gap(    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        %args,
        guest       => MockGuest->new( rc => 0 ),
        destination => $landed,
    );
    ok( !$quiet, 'a destination with state in it is not complained about' );

    # Nothing under the path on the guest: either it was never created, or the
    # service has not written into it.  Both are what a first build looks like,
    # and the fetch reads what the service owns now, so neither is unreadable.
    my $absent = Trog::Provisioner::Config::Generator::_salvage_gap(    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        %args,
        guest       => MockGuest->new( rc => 1 ),
        destination => $empty,
    );
    ok( $absent,              'a path holding nothing is still reported' );
    ok( !$absent->{alarming}, 'but not as a problem, because that is what a first build looks like' );
    like( $absent->{message}, qr/nothing[ ]to[ ]salvage/, 'and it says why there was nothing' );

    # The one that matters: the guest has files there and we came away with none.
    my $lost = Trog::Provisioner::Config::Generator::_salvage_gap(      ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
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
    unlike( $lost->{message}, qr/cannot[ ]read|unprivileged|no[ ]sudo/, 'and does not blame a permission that is no longer the cause' );
    is( $lost->{recipe}, 'redis', 'the recipe comes back out for the summary at the end of the run' );

    # test exits 0 or 1 and nothing else, so anything else is the question not
    # having been asked -- a guest that went away mid-run, or a sudo refused.
    # Filing that as a service which has never run would put the alarm out on
    # state that is still there.
    my $dropped = Trog::Provisioner::Config::Generator::_salvage_gap(    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        %args,
        guest       => MockGuest->new( rc => 255 ),
        destination => $empty,
    );
    ok( $dropped->{alarming}, 'a check that could not be run at all stays a problem' );
    like( $dropped->{message}, qr/could[ ]not[ ]ask/, 'and says that is what happened, rather than guessing' );
};

subtest 'an empty tree of directories is not a salvage' => sub {

    # rget makes the local directories on the way down whether or not it can read
    # what is inside them, so this is exactly what an unreadable fetch leaves.
    my $dir = "$salvage_root/slapd";
    mkdir $dir           or die "Could not create $dir: $!";
    mkdir "$dir/slapd.d" or die "Could not create $dir/slapd.d: $!";

    ok(
        !Trog::Provisioner::Config::Generator::_dir_has_files($dir),    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        'directories alone do not count as anything having landed'
    );

    open( my $fh, '>', "$dir/slapd.d/olcDatabase.ldif" ) or die "Could not write into $dir/slapd.d: $!";
    close($fh)                                           or die "Could not close $dir/slapd.d/olcDatabase.ldif: $!";

    ok(
        Trog::Provisioner::Config::Generator::_dir_has_files($dir),     ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        'a file anywhere underneath does'
    );

    ok(
        !Trog::Provisioner::Config::Generator::_dir_has_files("$salvage_root/never-made"),    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        'and a destination nothing ever created has nothing in it'
    );

    # A symlink counts as having landed, and is not walked into: one salvaged off
    # a guest can point anywhere, including back at the tree it sits in.
    my $links = "$salvage_root/links";
    mkdir $links                     or die "Could not create $links: $!";
    symlink( $links, "$links/loop" ) or die "Could not symlink into $links: $!";

    ok(
        Trog::Provisioner::Config::Generator::_dir_has_files($links),    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        'a symlink is something, and looking at it does not walk into itself'
    );
};

done_testing();
