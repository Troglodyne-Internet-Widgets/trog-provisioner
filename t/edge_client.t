#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/edge_client.t - scripts/edge_client: what it writes for a domain, what it
refuses, and what it prints

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Capture::Tiny    qw{capture};
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

my $script = "$FindBin::Bin/../scripts/edge_client";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $DOMAIN = 'web.test.test';
my @NAMES  = qw{public.web.test.test www.customer.test};

# A fresh directory of registrations, and every command answered: ssh-keygen
# makes a key where it is told to, and nginx says what $nginx_ok says.  Answers
# the commands that ran.
my $nginx_ok;
my @ran;

sub fresh_edge {
    no warnings 'once';
    $Trog::EdgeClient::EDGE_D = File::Temp::tempdir( CLEANUP => 1 );
    @ran                      = ();
    $nginx_ok                 = 1;
    return $Trog::EdgeClient::EDGE_D;
}

my $client = Test::MockModule->new( 'Trog::EdgeClient', no_auto => 1 );
$client->redefine(
    run => sub {
        my (@command) = @_;
        my $opts = ref $command[0] eq 'HASH' ? shift @command : {};
        push( @ran, "@command" );

        # doveadm hashes what it reads, twice over, on its standard input.
        if ( "@command" eq 'setsid --wait doveadm pw -s ARGON2ID' ) {
            my ( $first, $second ) = split m/\n/, $opts->{input} // q{};
            return ( "{ARGON2ID}hash-of-$first\n", $first eq $second ? 1 : 0 );
        }
        if ( $command[0] eq 'ssh-keygen' ) {
            my ($file) = map { $command[ $_ + 1 ] } grep { $command[$_] eq '-f' } 0 .. $#command;
            File::Slurper::Temp::write_text( $file,       "PRIVATE KEY\n" );
            File::Slurper::Temp::write_text( "$file.pub", "ssh-ed25519 AAAAbogus bans of $DOMAIN\n" );
            return ( q{}, 1 );
        }
        return ( 'nginx said no', $nginx_ok ) if $command[0] eq 'nginx';
        return ( q{},             1 );
    }
);

# What register printed, what it said on standard error or died with, and its
# exit status, which is undef when it died.
sub register {
    my (@args) = @_;
    my $died;
    my ( $out, $err, $rc ) = capture {
        my $status = eval { Trog::EdgeClient::main( 'register', @args ) };
        $died = $@;
        $status;
    };
    return ( $out, $err . $died, $rc );
}

subtest 'a domain registers each name, for TLS and for plain HTTP, and gets a key' => sub {
    my $edge = fresh_edge();
    my ( $out, $err, $rc ) = register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );

    is( $rc,                                                0,                                                                             'it exits 0' ) or diag $err;
    is( File::Slurper::read_text("$edge/$DOMAIN.tls.map"),  "public.web.test.test 192.0.2.10:8443;\nwww.customer.test 192.0.2.10:8443;\n", 'each name goes to the TLS port of the guest by its SNI name' );
    is( File::Slurper::read_text("$edge/$DOMAIN.http.map"), "public.web.test.test 192.0.2.10:8080;\nwww.customer.test 192.0.2.10:8080;\n", 'and to its HTTP port by its Host header' );
    is( MIME::Base64::decode_base64($out),                  "PRIVATE KEY\n",                                                               'it prints the private half of the key, in base64' );
    unlike( $out, qr/\n/, 'on one line, which is what bin/provision takes from it' );
    my $authorized = File::Slurper::read_text("$edge/authorized_keys.root");
    my $command    = qr/command="\S+\/edge_ban[ ]\Q$DOMAIN\E"/;
    my $options    = qr/restrict,from="192[.]0[.]2[.]10",$command/;
    like( $authorized, qr/\A$options[ ]ssh-ed25519[ ]AAAAbogus[ ]/, 'and authorizes the public half for root, to run edge_ban for the domain from the address of its guest' );
    is_deeply( [ grep { m/\A(?:nginx|systemctl)/ } @ran ], [ 'nginx -t', 'systemctl reload nginx' ], 'after nginx accepts the files, it reloads nginx' );

    register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 www.customer.test} );
    is( File::Slurper::read_text("$edge/$DOMAIN.tls.map"), "www.customer.test 192.0.2.10:8443;\n", 'a second registration replaces the first' );
};

subtest 'root takes only a key that is restricted' => sub {
    my $edge = fresh_edge();
    File::Slurper::Temp::write_text( "$edge/old.test.test.ban.pub", "ssh-ed25519 AAAAbare bans of old.test.test\n" );

    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );
    my @lines = split m/\n/, File::Slurper::read_text("$edge/authorized_keys.root");
    is( scalar @lines, 1, 'a bare public key in edge.d is not authorized, because it would log in as root with no restriction' );
    like( $lines[0], qr/\Q$DOMAIN\E/, 'and the restricted key of the domain is' );
};

subtest 'a name that another domain registered is refused' => sub {
    my $edge = fresh_edge();
    File::Slurper::Temp::write_text( "$edge/other.test.test.tls.map", "www.customer.test 192.0.2.11:8443;\n" );

    my ( $out, $err ) = register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );
    my $holds = qr/www[.]customer[.]test[ ]is[ ]registered/;
    like( $err, qr/$holds[ ]to[ ]other[.]test[.]test/, 'the refusal names the domain that holds it' );
    is( $out, q{}, 'and it prints no key' );
    ok( !-e "$edge/$DOMAIN.tls.map", 'and writes nothing for the domain' );
};

subtest 'what nginx refuses is taken back' => sub {
    my $edge = fresh_edge();
    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );
    my $before = File::Slurper::read_text("$edge/$DOMAIN.tls.map");

    $nginx_ok = 0;
    my ( $out, $err ) = register( $DOMAIN, '192.0.2.12:8443', '192.0.2.12:8080', @NAMES );
    like( $err, qr/nginx[ ]said[ ]no/, 'the error has what nginx said' );
    is( $out,                                              q{},     'and it prints no key' );
    is( File::Slurper::read_text("$edge/$DOMAIN.tls.map"), $before, 'and the domain keeps what it had' );

    register(qw{new.test.test 192.0.2.13:8443 192.0.2.13:8080 new.test.test});
    ok( !-e "$edge/new.test.test.tls.map", 'and a domain that had nothing keeps nothing' );
};

subtest 'a domain releases everything that it registered' => sub {
    my $edge = fresh_edge();
    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );

    $client->redefine( reload_nginx => sub { die "nginx is not up\n" } );
    my ( undef, $err, $rc ) = capture { Trog::EdgeClient::main( 'release', $DOMAIN ) };
    $client->unmock('reload_nginx');

    is( $rc, 0, 'it exits 0' );
    is_deeply( [ glob("$edge/$DOMAIN.*") ], [], 'and the maps and the key of the domain are gone' );
    is( File::Slurper::read_text("$edge/authorized_keys.root"), q{}, 'and root no longer takes the key' );
    like( $err, qr/nginx[ ]is[ ]not[ ]up/, 'an nginx that does not reload is a warning, because it reads the files when it starts' );

    ( undef, undef, $rc ) = capture { Trog::EdgeClient::main( 'release', $DOMAIN ) };
    is( $rc, 0, 'a domain that registered nothing releases nothing, and that is no error' );
};

# The lock of $edge, held as another edge_client holds it, until it is closed.
sub held_lock {
    my ($edge) = @_;
    open( my $held, '>>', "$edge/.lock" ) or die "Cannot open the lock: $!";
    flock( $held, Fcntl::LOCK_EX() )      or die "Cannot take the lock: $!";
    return $held;
}

subtest 'a registration waits for another one, but not forever' => sub {
    my $edge = fresh_edge();
    local $Trog::EdgeClient::LOCK_WAIT = 0.5;

    my $held  = held_lock($edge);
    my $start = Time::HiRes::time();
    my $err   = exception { Trog::EdgeClient::lock_edge() };
    my $took  = Time::HiRes::time() - $start;
    like( $err, qr/held[ ]\S+\/[.]lock[ ]for[ ]all[ ]of[ ]the[ ]0[.]5[ ]seconds/, 'a lock that another one holds for too long is an error that names the file' );
    cmp_ok( $took, '>=', 0.5, 'after the whole of the wait' );

    # A child that lets go partway through the wait.
    local $Trog::EdgeClient::LOCK_WAIT = 5;
    my $pid = fork() // die "Cannot fork: $!";
    if ( !$pid ) {
        Time::HiRes::sleep(0.5);
        POSIX::_exit( close($held) ? 0 : 1 );
    }
    close $held or die "Cannot close the lock: $!";
    ok( Trog::EdgeClient::lock_edge(), 'and the lock that the other one gives back is taken' );
    waitpid( $pid, 0 );
};

subtest 'a domain registers a login for the relay, and releases it' => sub {
    no warnings 'once';
    local $Trog::EdgeClient::DOVECOT_GROUP = getgrgid($));
    my $edge = fresh_edge();

    my ( $out, $err, $rc ) = capture { Trog::EdgeClient::main( 'register-mail', $DOMAIN ) };
    is( $rc, 0, 'it exits 0' ) or diag $err;
    chomp( my $password = $out );
    like( $password, qr/\A[[:xdigit:]]{48}\z/, 'and prints a password on one line' );

    is(
        File::Slurper::read_text("$edge/mail.passwd"), "$DOMAIN:{ARGON2ID}hash-of-$password
", 'dovecot gets a login named for the domain, with the hash that doveadm made of the password, which is not kept'
    );
    ok( ( grep { $_ eq 'setsid --wait doveadm pw -s ARGON2ID' } @ran ), 'doveadm reads the password on its input, away from the terminal, and not on its command line' );
    is( ( stat "$edge/mail.passwd" )[2] & oct 7777,     oct 640,               'readable by its group, and not by everybody' );
    is( File::Slurper::read_text("$edge/mail.senders"), "\@$DOMAIN $DOMAIN\n", 'and the login owns every sender in the domain' );
    is_deeply( [ grep { m/\A(?:systemctl)/ } @ran ], ['systemctl reload postfix'], 'and postfix reads the tables again' );

    capture { Trog::EdgeClient::main( 'register-mail', 'other.test.test' ) };
    my ( $second, undef, undef ) = capture { Trog::EdgeClient::main( 'register-mail', $DOMAIN ) };
    my @logins = map { m/\A([^:]+):/ } split m/\n/, File::Slurper::read_text("$edge/mail.passwd");
    is_deeply( \@logins, [ 'other.test.test', $DOMAIN ], 'a second registration replaces the login of the domain, beside the others' );
    isnt( $second, $out, 'with a new password' );

    ( undef, undef, $rc ) = capture { Trog::EdgeClient::main( 'release-mail', $DOMAIN ) };
    is( $rc,                                            0,                                     'a release exits 0' );
    is( File::Slurper::read_text("$edge/mail.senders"), "\@other.test.test other.test.test\n", 'and takes away the login of the domain only' );
    unlike( File::Slurper::read_text("$edge/mail.passwd"), qr/\Q$DOMAIN\E/, 'and its hash' );
    like( exception { Trog::EdgeClient::main( 'register-mail', $DOMAIN, 'extra' ) }, qr/\Ausage:/, 'and a registration with more than the domain is refused' );
};

subtest 'it refuses what it cannot put in a file of nginx' => sub {
    fresh_edge();
    my %bad = (
        'an upstream with no port'   => [ $DOMAIN,                                      '192.0.2.10', '192.0.2.10:8080', @NAMES ],
        'an upstream that is a name' => [ $DOMAIN,                                      'web:8443',   '192.0.2.10:8080', @NAMES ],
        'no name'                    => [ $DOMAIN,                                      qw{192.0.2.10:8443 192.0.2.10:8080} ],
        'a name with a semicolon'    => [ $DOMAIN,                                      qw{192.0.2.10:8443 192.0.2.10:8080 a.test;b} ],
        'a domain in upper case'     => [ qw{WEB.test 192.0.2.10:8443 192.0.2.10:8080}, @NAMES ],
    );
    foreach my $case ( sort keys %bad ) {
        like( exception { Trog::EdgeClient::main( 'register', @{ $bad{$case} } ) }, qr/\Ausage:/, $case );
    }
    like( exception { Trog::EdgeClient::main( 'release', $DOMAIN, 'extra' ) }, qr/\Ausage:/, 'a release with more than the domain' );
    is_deeply( \@ran, [], 'and none of them ran anything' );
};

done_testing;
