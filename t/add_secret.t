#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/add_secret.t - bin/add_secret: putting one secret in, and the three times it must not

=cut

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Test::More;
use File::Temp();
use Trog::Secrets();
use Trog::Credentials();

require_ok("$FindBin::Bin/../bin/add_secret") or die "could not require SUT: $@";

sub store {
    my $dir  = File::Temp::tempdir( CLEANUP => 1 );
    my $kdbx = "$dir/secrets.kdbx";

    # Something already in it, so this is a store being added to rather than made.
    Trog::Secrets->write( $kdbx, 'throwaway', 'secret:seed/entry/password' => 'already here' );
    return $kdbx;
}

sub add {
    my (@args) = @_;
    Trog::Credentials->forget();
    Trog::Credentials->remember( 'keepass', 'throwaway' );
    return Provisioner::Bin::add_secret::main(@args);
}

subtest 'a secret that was not there' => sub {
    my $kdbx = store();

    my $rc = add( '--secrets', $kdbx, '--group', 'troglodyne', '--title', 'easydns_token', '--', 'hunter2' );
    is( $rc, 0, 'it reports success' );

    my %got = Trog::Secrets->read( $kdbx, 'throwaway', probe => 'secret:troglodyne/easydns_token/password' );
    is( $got{probe}, 'hunter2', 'and the store holds it' );

    # The one that was there before is still there: saving rewrites the whole
    # database, and every other domain is provisioned out of the same file.
    my %seed = Trog::Secrets->read( $kdbx, 'throwaway', probe => 'secret:seed/entry/password' );
    is( $seed{probe}, 'already here', 'without disturbing what was already in it' );
};

subtest 'the field defaults to password, and username works too' => sub {
    my $kdbx = store();

    is( add( '--secrets', $kdbx, '--group', 'troglodyne', '--title', 'tok', '--field', 'username', '--', 'someuser' ), 0, 'a username is stored' );
    my %got = Trog::Secrets->read( $kdbx, 'throwaway', probe => 'secret:troglodyne/tok/username' );
    is( $got{probe}, 'someuser', 'under the field it was given' );
};

subtest 'a reference that already holds something is left alone' => sub {
    my $kdbx = store();

    # The same value is not a change, so it is not a failure either.
    is( add( '--secrets', $kdbx, '--group', 'seed', '--title', 'entry', '--', 'already here' ), 0, 'storing what is already there is fine' );

    # A different one is refused rather than rotated: whatever authenticated
    # with the old secret stops working, and that is not a thing to do while
    # adding a missing entry.
    my $rc;
    my @said;
    {
        local $SIG{__WARN__} = sub { push @said, @_ };
        $rc = add( '--secrets', $kdbx, '--group', 'seed', '--title', 'entry', '--', 'something else' );
    }
    isnt( $rc, 0, 'a different value is refused' );
    like( join( '', @said ), qr/will not replace it/, 'and says why' );

    my %got = Trog::Secrets->read( $kdbx, 'throwaway', probe => 'secret:seed/entry/password' );
    is( $got{probe}, 'already here', 'leaving the store as it was' );
};

subtest 'a field the database does not keep is an error, not a success' => sub {
    my $kdbx = store();

    # KeePass keeps password and username; anything else is dropped on save,
    # and a tool that reported success would have written nothing.
    my $rc = eval { add( '--secrets', $kdbx, '--group', 'g', '--title', 't', '--field', 'notes', '--', 'value' ) };
    is( $rc, undef, 'it dies rather than returning' );
    like( $@, qr/password or username/, 'naming the fields that are kept' ) or diag $@;
};

done_testing();
