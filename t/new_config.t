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

# A stand-in for the sftp session, which is the only part of the salvage check
# that has to be a guest.  Two answers are all _salvage_gap asks it for: whether
# the path stats, and the status code behind a stat that did not.
{

    package MockSFTP;

    sub new    { my ( $class, %args ) = @_; return bless {%args}, $class }
    sub stat   { my ($self) = @_; return $self->{found} ? {} : undef }
    sub status { my ($self) = @_; return $self->{status} }
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
        ssh         => MockSFTP->new( found => 1 ),
        destination => $landed,
    );
    ok( !$quiet, 'a destination with state in it is not complained about' );

    # 2 is SSH2_FX_NO_SUCH_FILE: the service has not generated anything yet.
    my $absent = Trog::Provisioner::Config::Generator::_salvage_gap(
        %args,
        ssh         => MockSFTP->new( found => 0, status => 2 ),
        destination => $empty,
    );
    ok( $absent,              'a path the guest does not have is still reported' );
    ok( !$absent->{alarming}, 'but not as a problem, because that is what a first build looks like' );
    like( $absent->{message}, qr/nothing to salvage/, 'and it says why there was nothing' );

    # The one that matters: the directory is there, and we came away with nothing.
    my $unreadable = Trog::Provisioner::Config::Generator::_salvage_gap(
        %args,
        ssh         => MockSFTP->new( found => 1 ),
        destination => $empty,
    );
    ok( $unreadable->{alarming}, 'a path that is there but yielded nothing is a problem' );
    like( $unreadable->{message}, qr/redis/,              'the message names the recipe' );
    like( $unreadable->{message}, qr{/var/lib/redis},     'and the path on the guest' );
    like( $unreadable->{message}, qr/tester cannot read/, 'and who could not read it' );
    like( $unreadable->{message}, qr/\Q$empty\E/,         'and where the nothing landed' );
    is( $unreadable->{recipe}, 'redis', 'the recipe comes back out for the summary at the end of the run' );

    # A guest that went away mid-run also fails to stat, and filing that as a
    # service which has never run would silence the alarm on real state.
    my $dropped = Trog::Provisioner::Config::Generator::_salvage_gap(
        %args,
        ssh         => MockSFTP->new( found => 0, status => 4 ),
        destination => $empty,
    );
    ok( $dropped->{alarming}, 'a stat that failed for any other reason stays a problem' );
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
