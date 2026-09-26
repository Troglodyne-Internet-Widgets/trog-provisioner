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
use IPC::Run3();

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

    sub capture_cmd {
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

    sub domain_dir { return '/bogus/domains' }
}

subtest 'a key the store never gave up is said so, rather than handed to ssh as nothing' => sub {
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( new => sub { return bless {}, 'FakeHV' } );

    # What a script gets: key_path asks for the store's password, nothing is
    # typed, and it comes back undef.
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { return undef } );

    # A uri, so hypervisor() takes its first branch and asks Trog::HV directly.
    my $err = exception { Trog::Skill::CollectArtifacts::connect_to( 'vm.test', uri => 'qemu:///bogus' ) };

    # \s+ rather than spaces: this file is under re '/aasx', so a literal space
    # in a pattern is ignored and the match would pass on anything.
    like( $err, qr/No \s+ key \s+ for \s+ vm[.]test/,   'names the domain it has no key for' );
    like( $err, qr/password \s+ goes \s+ on \s+ stdin/, 'and says how to give the store one' );
    unlike( $err, qr/Permission \s+ denied/, 'instead of leaving ssh to report a refusal it cannot explain' );
};

done_testing();
