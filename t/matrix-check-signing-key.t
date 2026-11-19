#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/matrix-check-signing-key.t - scripts/matrix_check_signing_key: a restored
database with a key that did not sign it

=cut

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use Cpanel::JSON::XS();
use DBI();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/matrix_check_signing_key";

my $SERVER = 'hs.test.test';

sub check {
    my (@args) = @_;
    IPC::Run3::run3( [ $script, @args ], \undef, \my $out, \my $err );
    return { rc => $? >> 8, said => ( $out // '' ) . ( $err // '' ) };
}

# A key file of version $version, as the signing key of the homeserver is.
sub key_file {
    my ( $dir, $version ) = @_;
    File::Slurper::Temp::write_text( "$dir/signing.key", "ed25519 $version AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n" );
    return "$dir/signing.key";
}

# A database with the two tables of synapse that the script reads, and one
# event for each of @events: [ sender, { server => [ key IDs that signed ] } ],
# oldest first.
sub database {
    my ( $dir, @events ) = @_;
    my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/homeserver.db", q{}, q{}, { RaiseError => 1 } );
    $dbh->do('CREATE TABLE events (event_id TEXT PRIMARY KEY, sender TEXT, stream_ordering INTEGER UNIQUE)');
    $dbh->do('CREATE TABLE event_json (event_id TEXT PRIMARY KEY, json TEXT)');
    my $n = 0;
    foreach my $event (@events) {
        my ( $sender, $signed_by ) = @$event;
        $n++;
        my %signatures = map {
            my $server = $_;
            ( $server => { map { $_ => 'c2lnbmF0dXJl' } @{ $signed_by->{$server} } } )
        } keys %$signed_by;
        $dbh->do( 'INSERT INTO events VALUES (?, ?, ?)', undef, "\$e$n", $sender, $n );
        $dbh->do( 'INSERT INTO event_json VALUES (?, ?)', undef, "\$e$n", Cpanel::JSON::XS->new->canonical->encode( { sender => $sender, signatures => \%signatures } ) );
    }
    $dbh->disconnect;
    return "$dir/homeserver.db";
}

subtest 'a first build has no database, and nothing to keep' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    my $r   = check( "$tmp/homeserver.db", $SERVER, key_file( $tmp, 'a_new' ) );
    is( $r->{rc}, 0, 'it passes' ) or diag $r->{said};
};

subtest 'a database with no event from this server has no key to keep' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    my $db  = database( $tmp, [ '@someone:other.test', { 'other.test' => ['ed25519:a_oth'] } ] );
    my $r   = check( $db, $SERVER, key_file( $tmp, 'a_new' ) );
    is( $r->{rc}, 0, 'it passes' ) or diag $r->{said};
};

subtest 'a database that the key signed is this homeserver' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    my $db  = database( $tmp, [ "\@admin:$SERVER", { $SERVER => ['ed25519:a_key'] } ], [ '@someone:other.test', { 'other.test' => ['ed25519:a_oth'] } ] );
    my $r   = check( $db, $SERVER, key_file( $tmp, 'a_key' ) );
    is( $r->{rc}, 0, 'it passes' ) or diag $r->{said};
};

subtest 'a database that a different key signed is a homeserver that lost its key' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    my $db  = database( $tmp, [ "\@admin:$SERVER", { $SERVER => ['ed25519:a_key'] } ] );
    my $r   = check( $db, $SERVER, key_file( $tmp, 'a_new' ) );
    is( $r->{rc}, 1, 'it fails' );
    like( $r->{said}, qr/ed25519:a_new/, 'and names the key that did not sign' );

    my $other = check( database( tempdir( CLEANUP => 1 ), [ "\@admin:$SERVER", { 'other.test' => ['ed25519:a_new'] } ] ), $SERVER, key_file( $tmp, 'a_new' ) );
    is( $other->{rc}, 1, 'a signature of another server under the same key ID does not count' );
};

subtest 'an old key that signed the newest events still counts' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    my $db  = database( $tmp, [ "\@admin:$SERVER", { $SERVER => ['ed25519:a_old'] } ] );
    is( check( $db, $SERVER, key_file( $tmp, 'a_new' ), 'ed25519:a_old' )->{rc}, 0, 'when it is among the old key IDs' );
};

subtest 'only the newest events are read' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    my $db  = database( $tmp, [ "\@admin:$SERVER", { $SERVER => ['ed25519:a_key'] } ], map { [ "\@admin:$SERVER", { $SERVER => ['ed25519:a_gone'] } ] } 1 .. 200 );
    is( check( $db, $SERVER, key_file( $tmp, 'a_key' ) )->{rc}, 1, 'a key that signed only events older than the newest 200 does not count' );
};

subtest 'what goes into the query must be a name' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    my $db  = database( $tmp, [ "\@admin:$SERVER", { $SERVER => ['ed25519:a_key'] } ] );
    is( check( $db, q{hs.test.test' OR 1=1 --}, key_file( $tmp, 'a_key' ) )->{rc}, 2, 'a server name with a quote in it is refused' );
    is( check( $db, $SERVER, key_file( $tmp, 'a_key' ), q{ed25519:a') OR (1=1} )->{rc}, 2, 'and so is an old key ID' );
};

done_testing();
