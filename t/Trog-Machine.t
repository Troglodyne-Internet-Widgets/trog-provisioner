#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Trog-Machine.t - Trog::Machine: putting a directory somewhere, and not putting it twice

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

subtest 'what put_dir asks rsync for' => sub {
    my $mock = Test::MockModule->new('Trog::Machine');
    my @asked;
    $mock->redefine( mkpath => sub { 1 } );
    $mock->redefine( _rsync => sub { shift; push( @asked, [@_] ); 1 } );

    ok( remote()->put_dir( '/bogus/data/vm.test', '/bogus/data/vm.test' ), 'it goes' );

    is(
        $asked[0][0], '/bogus/data/vm.test/',
        'a trailing slash on the source, which is rsync for "the contents of this"'
    );
    is(
        $asked[0][1], 'doge@hv.test:/bogus/data/vm.test/',
        'and the far side named as the login it will arrive as'
    );

    # Not through rsync at all: sync_dir means "make sure the hypervisor has
    # this", and when the hypervisor is us it already does.
    my ( $local, $localmock ) = here();
    @asked = ();
    ok( $local->put_dir( '/bogus/data/vm.test', '/bogus/data/vm.test' ), 'a local machine says yes' );
    is( scalar(@asked), 0, 'without copying a directory onto itself' );
};

subtest 'a destination that cannot be made is not transferred into' => sub {
    my $mock = Test::MockModule->new('Trog::Machine');
    my $ran  = 0;
    $mock->redefine( mkpath => sub { 0 } );
    $mock->redefine( _rsync => sub { $ran++; 1 } );

    is( remote()->put_dir( '/bogus/data/vm.test', '/bogus/data/vm.test' ), 0, 'it says so' );
    is( $ran,                                                              0, 'and does not spend a transfer finding out' );
};

subtest 'what get_dir asks rsync for' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $mock = Test::MockModule->new('Trog::Machine');
    my @asked;
    $mock->redefine( _rsync => sub { shift; push( @asked, [@_] ); 1 } );

    ok( remote()->get_dir( '/bogus/lib/deluged', "$dir/deep/deluged", exclude => ['secrets.key'], update => 1 ), 'it comes' );

    is( $asked[0][0], 'doge@hv.test:/bogus/lib/deluged/', 'the guest is the source' );
    is( $asked[0][1], "$dir/deep/deluged/",               'and we are the destination' );
    is_deeply( { @{ $asked[0] }[ 2 .. $#{ $asked[0] } ] }, { exclude => ['secrets.key'], update => 1 }, 'with what must not come down, and what must not come back' );

    # rsync makes the last component of a destination and nothing above it, and
    # a salvage is pointed two or three levels into a data directory that may
    # itself be new this run.
    ok( -d "$dir/deep/deluged", 'the path above the destination is ours to make' );
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

Test::NoWarnings::had_no_warnings();
done_testing();
