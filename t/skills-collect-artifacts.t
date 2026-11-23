#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/skills-collect-artifacts.t - the provisioning-recipes collector: what it can see, and what it only believes is missing

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use File::Spec();
use IPC::Run3();
use Capture::Tiny qw{capture_stderr};

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

require_ok("$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts/collect_artifacts")
  or BAIL_OUT('the collector does not load');

# The two questions fetch asks a guest, and a record of how it asked them.
# file_exists answers the way a real guest does for anything inside root's home:
# no, whoever is asking, because the directory is 0700.
{

    package FakeGuest;

    sub new {
        my ( $class, %args ) = @_;
        return bless { asked => [], %args }, $class;
    }

    sub file_exists { return 0 }

    sub run_sudo {
        my ( $self, @argv ) = @_;
        push @{ $self->{asked} }, [@argv];
        return $self->{missing} ? 1 : 0;
    }

    sub capture_sudo {
        my ($self) = @_;
        return $self->{content};
    }
}

subtest 'a file inside the home directory of root comes back, rather than being reported absent' => sub {
    my $into  = tempdir( CLEANUP => 1 );
    my $guest = FakeGuest->new( content => "SPT=40000 DPT=443\n" );

    my $got = Trog::Skill::CollectArtifacts::fetch( $guest, 'vm.test', '/root/new-outblocked.log', $into );

    ok( $got->{ok}, 'the collector came away with it' )
      or diag "why not: " . ( $got->{why} // 'no reason given' );

    # Read only if there is one, so that a collector which decided the file was
    # missing fails here saying so, rather than dying on the read and taking the
    # rest of the file with it.
    my $local = "$into/new-outblocked.log";
    is( -e $local ? File::Slurper::read_text($local) : undef, "SPT=40000 DPT=443\n", 'and wrote what was in it' );

    # Asked without sudo, every file under root's home reads as absent -- which
    # is also what a guest whose firewall stopped nothing looks like, so the
    # collector reported one as the other and said nothing was wrong.
    is_deeply( $guest->{asked}[0], [qw{test -f /root/new-outblocked.log}], 'having asked as root, like the read that follows it' );
};

# The queue is a database, so the collector asks sqlite3 for what waits and
# what ran.  The commands are run here, over a queue that post_install made.
subtest 'the deferred work comes back out of the queue' => sub {
    my %probe = map { $_->[1] => $_->[0] } Trog::Skill::CollectArtifacts::probes();
    ok( $probe{'post_install.sh'} && $probe{'post_install.ran.sh'}, 'the collector asks for what waits and for what ran' ) or return;

    my $dir = tempdir( CLEANUP => 1 );
    my $ask = sub {
        my ($name) = @_;
        IPC::Run3::run3( [ 'bash', '-c', $probe{$name} =~ s{/root}{$dir}gr ], \undef, \my $out, \my $err );
        return $out // q{};
    };
    is( $ask->('post_install.ran.sh'), "no deferred work has run here\n", 'a guest that never queued any says so, rather than coming back empty' );

    my $post_install = "$FindBin::Bin/../scripts/post_install";
    local $ENV{POST_INSTALL_DB} = "$dir/post_install.db";
    foreach my $task ( [ 20, 'exit 3' ], [ 10, 'true' ] ) {
        local $ENV{POSTRUN_SLOT} = $task->[0];
        IPC::Run3::run3( [ $^X, $post_install, '--queue', $task->[1] ], \undef, \undef, \undef );
    }
    is( $ask->('post_install.sh'), "10\ttrue\n20\texit 3\n", 'what waits, by slot, before post_install runs' );

    IPC::Run3::run3( [ $^X, $post_install ], \undef, \undef, \undef );
    is( $ask->('post_install.sh'),     q{},                            'and nothing once it has' );
    is( $ask->('post_install.ran.sh'), "10\t0\ttrue\n20\t3\texit 3\n", 'what ran, with what each exited with' );
};

subtest 'the artifacts of a scratch guest go inside its configuration, which teardown removes' => sub {
    my $cfg = $ENV{TROG_PROVISIONER_CONFIG};

    # The script is required at runtime, so this is the only mention of the
    # package variable that the compiler sees.
    my $marker = do { no warnings 'once'; "$cfg/$Trog::Skill::Teardown::MARKER" };

    my $tmp       = File::Spec->tmpdir;
    my $elsewhere = Trog::Skill::CollectArtifacts::artifacts_dir('vm.test');
    like( $elsewhere, qr{\A\Q$tmp\E/trog-artifacts-vm[.]test-}, 'without the marker, a new directory in the temporary directory' );
    ok( -d $elsewhere, 'which is made' );
    rmdir $elsewhere or diag "Could not remove $elsewhere: $!";

    File::Slurper::Temp::write_text( $marker, "Built by this test.\n" );
    my $inside = Trog::Skill::CollectArtifacts::artifacts_dir('vm.test');
    like( $inside, qr{\A\Q$cfg\E/artifacts/vm[.]test-}, 'with the marker, a new directory in artifacts/ of the scratch configuration' );
    ok( -d $inside, 'which is made' );
    unlink $marker;
};

subtest 'a file that is genuinely not there is still reported missing' => sub {
    my $into  = tempdir( CLEANUP => 1 );
    my $guest = FakeGuest->new( missing => 1, content => 'never read' );

    my $got = Trog::Skill::CollectArtifacts::fetch( $guest, 'vm.test', '/root/new-outblocked.log', $into );

    ok( !$got->{ok}, 'not collected' );
    is( $got->{why}, 'not there', 'and says which of the two it was' );
    ok( !-e "$into/new-outblocked.log", 'with nothing written for it' );
};

# Enough of a hypervisor to get as far as the key.  Trog::HV is mocked rather
# than this script's own package: Test::MockModule loads what it is given, and
# the collector is required by path rather than from @INC, so naming it here is
# "Can't locate Trog/Skill/CollectArtifacts.pm" and a subtest that never runs.
{

    package FakeHV;

    sub domain_dir         { return '/bogus/domains' }
    sub inspection_address { return '192.0.2.10' }
    sub describe           { return 'a fake hypervisor' }

    # A guest that answers whoami, and keeps what it was built with.
    package FakeLogin;
    sub capture_cmd { return "admin\n" }

    package FakeAnswer;

    sub capture_cmd { return "someadmin\n" }
}

subtest 'a key the store never gave up is said so, rather than handed to ssh as nothing' => sub {
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( new => sub { return bless {}, 'FakeHV' } );

    # What a script gets: key_path asks for the store's password, nothing is
    # typed, and it comes back undef.
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { return undef } );

    # No fleet, so locate_guest asks Trog::HV directly.
    my $err = exception { Trog::Skill::CollectArtifacts::connect_to( 'vm.test', uri => 'qemu:///bogus' ) };

    # \s+ rather than spaces: this file is under re '/aasx', so a literal space
    # in a pattern is ignored and the match would pass on anything.
    like( $err, qr/No \s+ key \s+ for \s+ vm[.]test/,   'names the domain it has no key for' );
    like( $err, qr/password \s+ goes \s+ on \s+ stdin/, 'and says how to give the store one' );
    like( $err, qr/collect_artifacts \s+ --agent/,      'or how to log in through the ssh agent' );
    unlike( $err, qr/Permission \s+ denied/, 'instead of leaving ssh to report a refusal it cannot explain' );
};

subtest '--agent logs in through the ssh agent, and never asks the store for the key' => sub {
    local $ENV{SSH_AUTH_SOCK} = '/bogus/agent.sock';
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( new => sub { return bless {}, 'FakeHV' } );

    my %built;
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { die "key_path was asked, which opens the store\n" } );
    $guest->redefine( new      => sub { ( undef, %built ) = @_; return bless {}, 'FakeLogin' } );

    my $err = exception { Trog::Skill::CollectArtifacts::connect_to( 'vm.test', agent => 1, user => 'admin' ) };
    is( $err,             undef,        'the store is never asked for the key' ) or diag $err;
    is( $built{key_path}, undef,        'and the guest has no key, so ssh offers the keys of the agent' );
    is( $built{host},     '192.0.2.10', 'at the address from the hypervisor' );

    delete local $ENV{SSH_AUTH_SOCK};
    like( exception { Trog::Skill::CollectArtifacts::connect_to( 'vm.test', agent => 1, user => 'admin' ) }, qr/SSH_AUTH_SOCK \s+ is \s+ not \s+ set/, 'with no agent, --agent is refused' );
};

subtest '--agent and --key together are refused, because they are two ways to log in' => sub {
    local $ENV{SSH_AUTH_SOCK} = '/bogus/agent.sock';
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { die "key_path was asked, which opens the store\n" } );

    like( exception { Trog::Skill::CollectArtifacts::main(qw{--agent --key /bogus/key.rsa vm.test}) }, qr/two \s+ ways \s+ to \s+ log \s+ in/, 'from the command line' );
};

subtest 'a domain that shares the guest of another is collected from that guest' => sub {
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", "_shared:\n    host.test.test:\n        - tenant.test.test\n" );

    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( new => sub { return bless {}, 'FakeHV' } );
    my @keyed;
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { push( @keyed, [ @_[ 1, 2 ] ] ); return undef } );

    exception { Trog::Skill::CollectArtifacts::connect_to( 'tenant.test.test', uri => 'qemu:///bogus' ) };
    is_deeply( \@keyed, [ [ 'host.test.test', '/bogus/domains/host.test.test/key.rsa' ] ], 'the key is of the host, from its directory' );
    is( ( Trog::Skill::CollectArtifacts::artifacts('tenant.test.test') )[0], '/var/log/tenant.test.test.setup.log', 'and the setup log is still the log of the domain' );
};

subtest 'the guest is reached at its address, whatever its internal name, with the key of the store or with agent' => sub {
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", "_base:\n    _global: {}\nrelayed.test.test:\n    _global:\n        internal_name: guest.relayed.test.test\n" );
    Provisioner::Cookbook->forget();

    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( new => sub { return bless {}, 'FakeHV' } );

    # Where the guest is told that it is spoken to, and answers who it is.
    my ( @made, @keyed );
    my $answering = bless {}, 'FakeAnswer';
    my $guest     = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { push( @keyed, $_[1] ); return '/bogus/key.rsa' } );
    $guest->redefine( new => sub { my ( undef, %args ) = @_; push( @made, \%args ); return $answering } );

    capture_stderr { Trog::Skill::CollectArtifacts::connect_to( 'relayed.test.test', uri => 'qemu:///bogus', user => 'someadmin' ) };
    is( $made[-1]{host},     '192.0.2.10',     'the address from the hypervisor, which needs no record in DNS' );
    is( $made[-1]{key_path}, '/bogus/key.rsa', 'with the key of the store' );

    @keyed = ();
    local $ENV{SSH_AUTH_SOCK} = '/bogus/agent.sock';
    capture_stderr { Trog::Skill::CollectArtifacts::connect_to( 'relayed.test.test', uri => 'qemu:///bogus', user => 'someadmin', agent => 1 ) };
    is( $made[-1]{host}, '192.0.2.10', 'with agent, it is the address too' );
    is_deeply( \@keyed, [], 'and the store is not asked for a key' );
    ok( !defined $made[-1]{key_path}, 'the guest is given none, so ssh uses the agent' );

    capture_stderr { Trog::Skill::CollectArtifacts::connect_to( 'other.test.test', uri => 'qemu:///bogus', user => 'someadmin', host => '192.0.2.77' ) };
    is( $made[-1]{host}, '192.0.2.77', 'and --host overrides it' );
};

# A getaddrinfo that knows the names of %$known.
sub resolver {
    my ($known) = @_;
    return sub {
        my $ip = $known->{ $_[0] } or return ('Name or service not known');
        return ( q{}, { family => Socket::AF_INET(), socktype => Socket::SOCK_STREAM(), protocol => 0, addr => Socket::pack_sockaddr_in( 0, Socket::inet_aton($ip) ), canonname => undef } );
    };
}

subtest 'a guest that no hypervisor can say the address of is reached at the address of its name, or not at all' => sub {
    local $ENV{SSH_AUTH_SOCK} = '/bogus/agent.sock';
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( new => sub { return bless {}, 'FakeHV' } );
    my $unasked = Test::MockModule->new( 'FakeHV', no_auto => 1 );
    $unasked->redefine( inspection_address => sub { die "Nothing was typed for the store\n" } );
    my $socket = Test::MockModule->new('Socket');
    $socket->redefine( getaddrinfo => resolver( { 'vm.test.test' => '192.0.2.12' } ) );

    my @made;
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( new => sub { my ( undef, %args ) = @_; push( @made, \%args ); return bless {}, 'FakeAnswer' } );

    my $said = capture_stderr { Trog::Skill::CollectArtifacts::connect_to( 'vm.test.test', user => 'someadmin', agent => 1 ) };
    is( $made[-1]{host}, '192.0.2.12', 'the address that its name resolves to' );
    like( $said, qr/Nothing \s+ was \s+ typed/,                                 'and it says why the hypervisor could not say' );
    like( $said, qr/vm[.]test[.]test \s+ resolves \s+ to \s+ 192[.]0[.]2[.]12/, 'and where it went instead' );

    my $err;
    capture_stderr {
        $err = exception { Trog::Skill::CollectArtifacts::connect_to( 'gone.test.test', user => 'someadmin', agent => 1 ) }
    };
    like( $err, qr/nothing \s+ to \s+ connect \s+ to/, 'a name that does not resolve either is nothing to connect to' );
    like( $err, qr/--host/,                            'and it says how to give the address' );
};

done_testing();
