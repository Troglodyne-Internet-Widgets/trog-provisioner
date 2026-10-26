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

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/mailrelay_client";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $DOMAIN = 'web.test.test';

# A fresh directory of registrations, and every command answered.  Answers the
# commands that ran.
my @ran;

sub fresh_relay {
    no warnings 'once';
    $Trog::MailRelayClient::RELAY_D = File::Temp::tempdir( CLEANUP => 1 );
    @ran                            = ();
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
        return ( q{}, 1 );
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
    like( exception { Trog::MailRelayClient::main( 'register', $DOMAIN ) },                        qr/\Ausage:/, 'a registration without the address of the guest is refused' );
    like( exception { Trog::MailRelayClient::main( 'register', $DOMAIN, 'web.test.test' ) },       qr/\Ausage:/, 'and one with a name for an address' );
    like( exception { Trog::MailRelayClient::main( 'register', $DOMAIN, '192.0.2.10', 'extra' ) }, qr/\Ausage:/, 'and one with more' );
    like( exception { Trog::MailRelayClient::main(qw{register WEB.test 192.0.2.10}) },             qr/\Ausage:/, 'and a domain in upper case' );
    like( exception { Trog::MailRelayClient::main( 'release', $DOMAIN, 'extra' ) },                qr/\Ausage:/, 'and a release with more than the domain' );
    is_deeply( \@ran, [], 'and none of them ran anything' );
};

done_testing;
