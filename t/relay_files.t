#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/relay_files.t - scripts/relay_files: the lock and the ban keys that the relay
clients share

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp();
use File::Slurper();
use File::Slurper::Temp();
use MIME::Base64();
use Fcntl();
use POSIX();
use Time::HiRes();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/relay_files";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# The lock of $dir, held as another client holds it, until it is closed.
sub held_lock {
    my ($dir) = @_;
    open( my $held, '>>', "$dir/.lock" ) or die "Cannot open the lock: $!";
    flock( $held, Fcntl::LOCK_EX() )     or die "Cannot take the lock: $!";
    return $held;
}

subtest 'a registration waits for another one, but not forever' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    local $Trog::RelayFiles::LOCK_WAIT = 0.5;

    my $held  = held_lock($dir);
    my $start = Time::HiRes::time();
    my $err   = exception { Trog::RelayFiles::lock_dir( $dir, 'some_client' ) };
    my $took  = Time::HiRes::time() - $start;
    like( $err, qr/held[ ]\S+\/[.]lock[ ]for[ ]all[ ]of[ ]the[ ]0[.]5[ ]seconds/, 'a lock that another one holds for too long is an error that names the file' );
    like( $err, qr/-C[ ]some_client[ ]shows/,                                     'and the client to look for' );
    cmp_ok( $took, '>=', 0.5, 'after the whole of the wait' );

    # A child that lets go partway through the wait.
    local $Trog::RelayFiles::LOCK_WAIT = 5;
    my $pid = fork() // die "Cannot fork: $!";
    if ( !$pid ) {
        Time::HiRes::sleep(0.5);
        POSIX::_exit( close($held) ? 0 : 1 );
    }
    close $held or die "Cannot close the lock: $!";
    ok( Trog::RelayFiles::lock_dir( $dir, 'some_client' ), 'and the lock that the other one gives back is taken' );
    waitpid( $pid, 0 );
};

subtest 'a ban key runs relay_ban for its domain and set, from its guest alone' => sub {
    my $dir       = File::Temp::tempdir( CLEANUP => 1 );
    my $files     = Test::MockModule->new( 'Trog::RelayFiles', no_auto => 1 );
    my $keygen_ok = 1;
    $files->redefine(
        run => sub {
            my (@command) = @_;
            return ( 'ssh-keygen said no', 0 ) unless $keygen_ok;
            my ($file) = map { $command[ $_ + 1 ] } grep { $command[$_] eq '-f' } 0 .. $#command;
            File::Slurper::Temp::write_text( $file,       "PRIVATE KEY\n" );
            File::Slurper::Temp::write_text( "$file.pub", "ssh-ed25519 AAAAbogus bans of web.test.test\n" );
            return ( q{}, 1 );
        }
    );

    my @for = qw{web.test.test 192.0.2.10 somerelay-bans};
    my $key = Trog::RelayFiles::issue_ban_key( $dir, @for );
    is( MIME::Base64::decode_base64($key), "PRIVATE KEY\n", 'the private half comes back in base64' );
    unlike( $key, qr/\n/, 'on one line' );
    my $authorized = File::Slurper::read_text("$dir/authorized_keys.root");
    my $ban        = qr/relay_ban[ ]somerelay-bans[ ]web[.]test[.]test/;
    my $command    = qr/command="\S+\/$ban"/;
    my $from       = qr/from="192[.]0[.]2[.]10"/;
    like( $authorized, qr/\Arestrict,$from,$command[ ]ssh-ed25519[ ]AAAAbogus[ ]/, 'and root takes the public half for relay_ban alone' );

    File::Slurper::Temp::write_text( "$dir/bare.test.test.ban.pub", "ssh-ed25519 AAAAbare bans of bare.test.test\n" );
    Trog::RelayFiles::write_authorized_keys($dir);
    is( scalar( () = File::Slurper::read_text("$dir/authorized_keys.root") =~ m/^/mg ), 1, 'a bare key is not authorized, because it would log in as root with no restriction' );

    $keygen_ok = 0;
    my $failed = qr/Could[ ]not[ ]make[ ]the[ ]key[ ]of[ ]web[.]test[.]test:/;
    like( exception { Trog::RelayFiles::issue_ban_key( $dir, @for ) }, qr/$failed[ ]ssh-keygen[ ]said[ ]no/, 'a failed ssh-keygen dies' );
    like( File::Slurper::read_text("$dir/authorized_keys.root"),       qr/AAAAbogus/,                        'and keeps the key that the domain had' );

    Trog::RelayFiles::revoke_ban_key( $dir, 'web.test.test' );
    ok( !-e "$dir/web.test.test.ban.pub", 'a revocation removes the key' );
    is( File::Slurper::read_text("$dir/authorized_keys.root"),                   q{},   'and root no longer takes it' );
    is( exception { Trog::RelayFiles::revoke_ban_key( $dir, 'web.test.test' ) }, undef, 'and a key that is gone already is no error' );
};

done_testing;
