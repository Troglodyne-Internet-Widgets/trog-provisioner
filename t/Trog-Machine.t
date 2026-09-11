#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Trog-Machine.t - Trog::Machine: fetching a directory, and not fetching it twice

=cut

# A -f in here is asserting on a file this test just made, in a temporary
# directory nothing else can see.  There is no window for it to be wrong in, so
# the TOCTOU policies have nothing to catch.
## no critic (ValuesAndExpressions::ProhibitFiletest_f)

use Test::More;
use Test::NoWarnings;
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Path();
use File::Slurper();
use File::Slurper::Temp();

use FindBin::libs;

use_ok('Trog::Machine') or BAIL_OUT('Trog::Machine does not load; the install is incomplete');

# A machine reached over the network, which none of these ever open a
# connection to: everything asserted on here is decided before rsync runs.
sub remote {
    return Trog::Machine->new(
        host     => 'hv.test',
        user     => 'doge',
        port     => 2222,
        key_path => '/bogus/domains/vm.test/key.rsa',
        @_,
    );
}

# The same object, but the machine is us.  rsync still runs; ssh does not.
sub here {
    my $machine = Trog::Machine->new(@_);
    my $mock    = Test::MockModule->new('Trog::Machine');
    $mock->redefine( is_local => sub { 1 } );
    return ( $machine, $mock );
}

subtest 'the ssh rsync is told to use' => sub {
    my $rsh = remote()->_rsh;

    like( $rsh, qr{\A ssh \s -p \s 2222 \b}x,                  'the port, which rsync cannot get from anywhere else' );
    like( $rsh, qr{-i \s /bogus/domains/vm[.]test/key[.]rsa}x, 'and the key, for the same reason' );

    # The same options Net::OpenSSH::More puts on its own master.  A guest
    # rebuilt an hour ago presents a host key nothing has seen before, and
    # refusing it would be this working exactly as intended and failing anyway.
    like( $rsh, qr{StrictHostKeyChecking=no},     'a host key nobody has seen is expected here' );
    like( $rsh, qr{UserKnownHostsFile=/dev/null}, 'and is not written down afterwards' );

    unlike( Trog::Machine->new( host => 'hv.test' )->_rsh, qr{-i}, 'no key, no -i naming a file that is not there' );
};

subtest 'every machine gets a connection of its own' => sub {

    # Net::OpenSSH::More caches connections by user, host and port, and hands
    # the cached one back without asking whether it still reaches anything.
    # Rebuilding a guest ran a command on the old one during the salvage and
    # then, in the same process, connected to the new one at the same address:
    # it got the old guest's connection, and the first command through it died
    # "Broken pipe".
    my %asked;
    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine( new => sub { my ( $class, %opts ) = @_; %asked = %opts; return bless {}, $class } );

    remote()->ssh;
    is( $asked{no_cache}, 1,         'the library is told not to share one' );
    is( $asked{host},     'hv.test', 'for the machine that was asked about' );
};

subtest 'the port the far side listens on' => sub {
    my $mock = Test::MockModule->new('Trog::Machine');
    my $asked;

    $mock->redefine(
        capture_cmd => sub {
            $asked = $_[1];
            return "2222\n";
        }
    );
    is( remote()->sshd_port, 2222, 'what its configuration says' );
    like( $asked, qr{sshd_config[.]d}, 'asked of the drop-in directory as well as the main file' );

    # No Port line is not a failure to find one: it is how every stock install
    # says 22.  Test::NoWarnings at the end of this file is the assertion that
    # nothing was said about it -- this used to warn, and now runs against
    # ourselves on every provision.
    $mock->redefine( capture_cmd => sub { return "\n" } );
    is( remote()->sshd_port, 22, 'and 22 when it says nothing' );
};

subtest 'what get_dir asks rsync for' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $mock = Test::MockModule->new('Trog::Machine');
    my @asked;
    $mock->redefine( _rsync => sub { shift; push( @asked, [@_] ); 1 } );

    ok( remote()->get_dir( '/bogus/lib/deluged', "$dir/deep/deluged", exclude => ['secrets.key'], update => 1, sudo => 1 ), 'it comes' );

    is( $asked[0][0], 'doge@hv.test:/bogus/lib/deluged/', 'the guest is the source' );
    is( $asked[0][1], "$dir/deep/deluged/",               'and we are the destination' );
    is_deeply(
        { @{ $asked[0] }[ 2 .. $#{ $asked[0] } ] },
        { exclude => ['secrets.key'], update => 1, sudo => 1 },
        'with what must not come down, what must not come back, and who to read it as'
    );

    # rsync makes the last component of a destination and nothing above it, and
    # a salvage is pointed two or three levels into a data directory that may
    # itself be new this run.
    ok( -d "$dir/deep/deluged", 'the path above the destination is ours to make' );
};

subtest 'a salvage never removes our copy of something the guest stopped having' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Path::make_path("$dir/src");
    File::Slurper::Temp::write_text( "$dir/src/state.db", "state\n" );

    my ( $machine, $mock ) = here();

    ok( $machine->get_dir( "$dir/src", "$dir/dst" ), 'the first fetch works' );
    ok( -f "$dir/dst/state.db",                      'and brings the state down' );

    # The guest stops producing it -- the service was reconfigured, or the file
    # was only ever there once.
    unlink("$dir/src/state.db") or die "could not remove the source: $!";

    $machine->get_dir( "$dir/src", "$dir/dst" );

    # rsync could delete it and must not.  This is the only copy: the domain
    # directory is where a salvage lands and nothing else keeps a history of it.
    # A backup mirrors its source and deletes on purpose, having yesterday to
    # fall back on; this has nothing behind it.
    ok( -f "$dir/dst/state.db", 'and a second fetch leaves behind what the guest no longer has' );
};

subtest 'a privileged fetch asks the far end to be root, and not to wait for a password' => sub {

    # A real destination, because get_dir makes the path above it before rsync
    # is reached -- see the subtest above.
    my $dir  = tempdir( CLEANUP => 1 );
    my $mock = Test::MockModule->new('File::Rsync');
    my %built;
    $mock->redefine( new  => sub { my ( $class, %args ) = @_; %built = %args; return bless {}, $class } );
    $mock->redefine( exec => sub { return 1 } );
    $mock->redefine( out  => sub { return [] } );

    remote()->get_dir( '/bogus/lib/redis', "$dir/redis", sudo => 1 );

    # A service keeps its state in a directory it owns and nobody else can open,
    # so an unprivileged rsync walks the tree, makes the local directories,
    # copies nothing out of them and exits happy -- which cannot be told from a
    # guest that has no state yet.
    is( $built{'rsync-path'}, 'sudo -n rsync', 'root at the far end' );

    # -n, because there is no terminal on the other end of this: a sudo that
    # decided to ask for a password would sit there until the timeout instead of
    # failing where somebody can see it.
    like( $built{'rsync-path'}, qr/\s-n\b/, 'and it fails rather than waiting when sudo would ask' );

    remote()->get_dir( '/bogus/lib/deluged', "$dir/deluged" );
    ok( !exists $built{'rsync-path'}, 'an ordinary fetch stays unprivileged' );
};

subtest 'rsync moves what changed and nothing else' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Path::make_path("$dir/src/config");
    File::Slurper::Temp::write_text( "$dir/src/state.db",           "state\n" );
    File::Slurper::Temp::write_text( "$dir/src/config/secrets.key", "do not travel\n" );

    my ( $machine, $mock ) = here();

    ok( $machine->get_dir( "$dir/src", "$dir/dst", exclude => ['secrets.key'] ), 'the first fetch works' );
    ok( -f "$dir/dst/state.db",                                                  'and brings the state down' );
    ok( !-f "$dir/dst/config/secrets.key",                                       'and leaves behind what was told to stay' );

    # The whole reason any of this is rsync.  A re-provision of a domain whose
    # data has not changed should cost a directory walk, not the data.
    #
    # Redirected at the file descriptor rather than by localising the glob:
    # File::Rsync captures the child through IPC::Run3, which saves and restores
    # the real STDOUT, and an in-memory handle in its place is not something it
    # can hand back.
    open( my $saved, '>&', \*STDOUT )    or die "could not save STDOUT: $!";
    open( STDOUT,    '>',  "$dir/said" ) or die "could not redirect STDOUT: $!";
    $machine->get_dir( "$dir/src", "$dir/dst", exclude => ['secrets.key'] );
    open( STDOUT, '>&', $saved ) or die "could not restore STDOUT: $!";

    like( File::Slurper::read_text("$dir/said"), qr{Total [ ] transferred [ ] file [ ] size: \s* 0\b}x, 'the second fetch moves nothing, and says so' );
};

subtest 'a transfer that fails says which one, and does not pretend' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my ( $machine, $mock ) = here();

    my @warnings;
    my $ok = do {
        local $SIG{__WARN__} = sub { push( @warnings, $_[0] ) };
        $machine->get_dir( "$dir/was-never-here", "$dir/dst" );
    };

    is( $ok, 0, 'it returns false rather than a count nobody checks' );
    like( $warnings[0], qr{was-never-here}, 'and names the transfer that failed' );
    like( $warnings[0], qr{rsync}i,         'as rsync, so the exit status below it means something' );
};

subtest 'a file read off a remote machine comes back whole' => sub {

    # Net::OpenSSH::capture returns one element per line in list context, and
    # _unhang calls what it is given in list context and hands a scalar caller
    # the first element -- so read_text came back as line one of the file.
    # Measured against a 233-line authorized_keys: 608 bytes of 128667.
    #
    # A one-line file read perfectly, which is why nothing caught it: the
    # callers that existed were reading a hypervisor's config values.
    my $file = "alpha\nbeta\ngamma\n";

    my $ssh  = FakeSSH->new($file);
    my $mock = Test::MockModule->new('Trog::Machine');
    $mock->redefine( is_local => sub { 0 } );
    $mock->redefine( ssh      => sub { $ssh } );

    my $got = remote()->read_text('/bogus/authorized_keys');
    is( $got, $file, 'every line of it, with the trailing newline the file has' );

    # The call has to say so itself; _unhang cannot know what its caller wanted.
    ok( $ssh->{scalar_context}, 'because capture was asked in scalar context' );
};

{
    # Net::OpenSSH's capture, in the one respect that matters here: a list of
    # lines or the whole thing, depending on what it was asked for.
    package FakeSSH;

    sub new { my ( $class, $content ) = @_; return bless { content => $content }, $class }

    sub capture {
        my ($self) = @_;
        $? = 0;    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read_text reads it, and a fake that does not set it tests nothing.
        if (wantarray) {
            $self->{scalar_context} = 0;
            return map { "$_\n" } split( "\n", $self->{content} );
        }
        $self->{scalar_context} = 1;
        return $self->{content};
    }
}

Test::NoWarnings::had_no_warnings();
done_testing();
