#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/mailrelay_client.t - scripts/mailrelay_client: the login and the route in
that it writes for a domain, what it refuses, and what it prints

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Capture::Tiny    qw{capture};
use Test::MockModule qw{strict};
use File::Temp();
use File::Slurper();
use File::Slurper::Temp();
use MIME::Base64();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/mailrelay_client";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $DOMAIN = 'web.test.test';

# Where the guest of $DOMAIN takes IMAP, submission and POP3 over TLS.
my @UPSTREAMS = qw{192.0.2.10:10993 192.0.2.10:10465 192.0.2.10:10995};

# A fresh directory of registrations, and every command answered.  Answers the
# commands that ran.
my @ran;
my $nginx_ok;

sub fresh_relay {
    no warnings 'once';
    $Trog::MailRelayClient::RELAY_D = File::Temp::tempdir( CLEANUP => 1 );
    @ran                            = ();
    $nginx_ok                       = 1;
    return $Trog::MailRelayClient::RELAY_D;
}

my $files = Test::MockModule->new( 'Trog::RelayFiles', no_auto => 1 );
$files->redefine(
    run => sub {
        my (@command) = @_;
        my $opts = ref $command[0] eq 'HASH' ? shift @command : {};
        push( @ran, "@command" );

        # doveadm hashes what it reads, twice over, on its standard input.
        if ( "@command" eq 'setsid --wait doveadm pw -s ARGON2ID' ) {
            my ( $first, $second ) = split m/\n/, $opts->{input} // q{};
            return ( "{ARGON2ID}hash-of-$first\n", $first eq $second ? 1 : 0 );
        }

        # ssh-keygen makes a key where it is told to.
        if ( $command[0] eq 'ssh-keygen' ) {
            my ($file) = map { $command[ $_ + 1 ] } grep { $command[$_] eq '-f' } 0 .. $#command;
            File::Slurper::Temp::write_text( $file,       "PRIVATE KEY\n" );
            File::Slurper::Temp::write_text( "$file.pub", "ssh-ed25519 AAAAbogus bans of $DOMAIN\n" );
            return ( q{}, 1 );
        }
        return ( 'nginx said no', 0 ) if "@command" eq 'nginx -t' && !$nginx_ok;
        return ( q{},             1 );
    }
);

subtest 'a domain registers a login for the relay, and releases it' => sub {
    no warnings 'once';
    local $Trog::MailRelayClient::DOVECOT_GROUP = getgrgid($));
    my $relay = fresh_relay();

    my ( $out, $err, $rc ) = capture { Trog::MailRelayClient::main( 'register', $DOMAIN, '192.0.2.10' ) };
    is( $rc, 0, 'it exits 0' ) or diag $err;
    chomp( my $password = $out );
    like( $password, qr/\A[[:xdigit:]]{48}\z/, 'and prints a password on one line' );

    is( File::Slurper::read_text("$relay/mail.passwd"), "$DOMAIN:{ARGON2ID}hash-of-$password\n", 'dovecot gets a login named for the domain, with the hash that doveadm made of the password, which is not kept' );
    ok( ( grep { $_ eq 'setsid --wait doveadm pw -s ARGON2ID' } @ran ), 'doveadm reads the password on its input, away from the terminal, and not on its command line' );
    is( ( stat "$relay/mail.passwd" )[2] & oct 7777,           oct 640,                          'readable by its group, and not by everybody' );
    is( File::Slurper::read_text("$relay/mail.senders"),       "\@$DOMAIN $DOMAIN\n",            'and the login owns every sender in the domain' );
    is( File::Slurper::read_text("$relay/mail.relay_domains"), "$DOMAIN OK\n",                   'the relay takes mail for the domain from the internet' );
    is( File::Slurper::read_text("$relay/mail.transport"),     "$DOMAIN smtp:[192.0.2.10]:25\n", 'and relays it to the guest, on 25' );
    is( File::Slurper::read_text("$relay/mail.recipients"),    "\@$DOMAIN OK\n",                 'for any recipient there, which the catchall of the guest delivers' );
    is_deeply( [ grep { m/\A(?:systemctl)/ } @ran ], ['systemctl reload postfix'], 'and postfix reads the tables again' );

    capture { Trog::MailRelayClient::main(qw{register other.test.test 192.0.2.11}) };
    my ( $second, undef, undef ) = capture { Trog::MailRelayClient::main( 'register', $DOMAIN, '192.0.2.12' ) };
    my @logins = map { m/\A([^:]+):/ } split m/\n/, File::Slurper::read_text("$relay/mail.passwd");
    is_deeply( \@logins, [ 'other.test.test', $DOMAIN ], 'a second registration replaces the login of the domain, beside the others' );
    isnt( $second, $out, 'with a new password' );

    ( undef, undef, $rc ) = capture { Trog::MailRelayClient::main( 'release', $DOMAIN ) };
    is( $rc,                                             0,                                     'a release exits 0' );
    is( File::Slurper::read_text("$relay/mail.senders"), "\@other.test.test other.test.test\n", 'and takes away the login of the domain only' );
    unlike( File::Slurper::read_text("$relay/mail.passwd"), qr/\Q$DOMAIN\E/, 'and its hash' );
    is( File::Slurper::read_text("$relay/mail.transport"), "other.test.test smtp:[192.0.2.11]:25\n", 'and its route in, leaving the others' );
};

subtest 'a domain registers the names of its mail clients, and gets a key for its bans' => sub {
    no warnings 'once';
    local $Trog::MailRelayClient::DOVECOT_GROUP = getgrgid($));
    my $dir   = fresh_relay();
    my @names = ( $DOMAIN, "mail.$DOMAIN" );

    my ( $key, $said, $exit ) = capture { Trog::MailRelayClient::main( 'register-clients', $DOMAIN, @UPSTREAMS, @names ) };
    is( $exit,                                                    0,                                                             'it exits 0' ) or diag $said;
    is( File::Slurper::read_text("$dir/$DOMAIN.imaps.map"),       "$DOMAIN 192.0.2.10:10993;\nmail.$DOMAIN 192.0.2.10:10993;\n", 'each name goes to IMAP over TLS on the guest' );
    is( File::Slurper::read_text("$dir/$DOMAIN.submissions.map"), "$DOMAIN 192.0.2.10:10465;\nmail.$DOMAIN 192.0.2.10:10465;\n", 'and to submission over TLS' );
    is( File::Slurper::read_text("$dir/$DOMAIN.pop3s.map"),       "$DOMAIN 192.0.2.10:10995;\nmail.$DOMAIN 192.0.2.10:10995;\n", 'and to POP3 over TLS' );
    is( MIME::Base64::decode_base64($key),                        "PRIVATE KEY\n",                                               'it prints the private half of the ban key, in base64' );
    my $ban_command = qr/command="\S+[ ]mailrelay-bans[ ]\Q$DOMAIN\E"/;
    like( File::Slurper::read_text("$dir/authorized_keys.root"), qr/\Arestrict,from="192[.]0[.]2[.]10",$ban_command/, 'which runs relay_ban for the set of this relay, from the guest alone' );
    is_deeply( [ grep { m/\A(?:nginx|systemctl)/ } @ran ], [ 'nginx -t', 'systemctl reload nginx' ], 'after nginx accepts the maps, it reloads nginx' );

    like( exception { Trog::MailRelayClient::main( 'register-clients', 'other.test.test', @UPSTREAMS, "mail.$DOMAIN" ) }, qr/mail[.]\Q$DOMAIN\E[ ]is[ ]registered[ ]to[ ]\Q$DOMAIN\E/, 'another domain cannot register a name that this one holds' );
    ok( !-e "$dir/other.test.test.imaps.map", 'and gets no map' );

    $nginx_ok = 0;
    my $before = File::Slurper::read_text("$dir/$DOMAIN.imaps.map");
    like( exception { Trog::MailRelayClient::main( 'register-clients', $DOMAIN, @UPSTREAMS, 'new.test.test' ) }, qr/nginx[ ]refused[ ].*nginx[ ]said[ ]no/, 'a map that nginx refuses is an error' );
    is( File::Slurper::read_text("$dir/$DOMAIN.imaps.map"), $before, 'and the domain keeps what it had' );

    $nginx_ok = 1;
    ( undef, undef, $exit ) = capture { Trog::MailRelayClient::main( 'release', $DOMAIN ) };
    is( $exit, 0, 'a release exits 0' );
    ok( !-e "$dir/$DOMAIN.$_.map", "and takes away the map of $_" ) foreach qw{imaps submissions pop3s};
    is( File::Slurper::read_text("$dir/authorized_keys.root"), q{}, 'and the ban key' );
};

subtest 'a postfix that is not up does not stop a release' => sub {
    no warnings 'once';
    local $Trog::MailRelayClient::DOVECOT_GROUP = getgrgid($));
    fresh_relay();
    my $client = Test::MockModule->new( 'Trog::MailRelayClient', no_auto => 1 );
    $client->redefine( reload_postfix => sub { die "postfix is not up\n" } );
    my ( undef, $warned, $status ) = capture { Trog::MailRelayClient::main( 'release', $DOMAIN ) };
    is( $status, 0, 'it exits 0' );
    like( $warned, qr/postfix[ ]is[ ]not[ ]up/, 'and warns, because postfix reads the tables when it starts' );
};

subtest 'it refuses what it cannot put in a table of postfix' => sub {
    fresh_relay();
    like( exception { Trog::MailRelayClient::main( 'register', $DOMAIN ) },                                       qr/\Ausage:/, 'a registration without the address of the guest is refused' );
    like( exception { Trog::MailRelayClient::main( 'register', $DOMAIN, 'web.test.test' ) },                      qr/\Ausage:/, 'and one with a name for an address' );
    like( exception { Trog::MailRelayClient::main( 'register', $DOMAIN, '192.0.2.10', 'extra' ) },                qr/\Ausage:/, 'and one with more' );
    like( exception { Trog::MailRelayClient::main(qw{register WEB.test 192.0.2.10}) },                            qr/\Ausage:/, 'and a domain in upper case' );
    like( exception { Trog::MailRelayClient::main( 'release', $DOMAIN, 'extra' ) },                               qr/\Ausage:/, 'and a release with more than the domain' );
    like( exception { Trog::MailRelayClient::main( 'register-clients', $DOMAIN, @UPSTREAMS ) },                   qr/\Ausage:/, 'and the mail clients of no name' );
    like( exception { Trog::MailRelayClient::main( 'register-clients', $DOMAIN, @UPSTREAMS[ 0, 1 ], $DOMAIN ) },  qr/\Ausage:/, 'and of a name for an upstream' );
    like( exception { Trog::MailRelayClient::main( 'register-clients', $DOMAIN, @UPSTREAMS, 'Mail.test.test' ) }, qr/\Ausage:/, 'and of a name in upper case' );
    is_deeply( \@ran, [], 'and none of them ran anything' );
};

done_testing;
