#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/restore-state.t - scripts/restore_state: putting salvaged state back, and the three times it must not

=cut

# Every filetest here is on a path this test just made in a temporary directory
# nothing else can see, so there is no window for it to be wrong in.
## no critic (ValuesAndExpressions::ProhibitFiletest_e, ValuesAndExpressions::ProhibitFiletest_d, ValuesAndExpressions::ProhibitFiletest_f, ValuesAndExpressions::ProhibitFiletest_rwxRWX)

use Test::More;
use File::Path    qw{make_path};
use File::Temp    qw{tempdir};
use File::Slurper qw{read_text};
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/restore_state";
ok( -x $script, 'restore_state is there and executable' );

sub restore {
    my (@args) = @_;
    IPC::Run3::run3( [ $script, @args ], \undef, \my $out, \my $err );
    return { rc => $? >> 8, said => ( $out // '' ) . ( $err // '' ) };
}

sub tree {
    my ( $dir, %files ) = @_;
    make_path($dir);
    while ( my ( $name, $content ) = each %files ) {
        File::Slurper::Temp::write_text( "$dir/$name", $content );
    }
    return $dir;
}

subtest 'a first build has nothing to restore' => sub {
    my $tmp = tempdir( CLEANUP => 1 );

    my $r = restore( "$tmp/never-fetched", "$tmp/destination" );
    is( $r->{rc}, 0, 'not an error' );
    ok( !-e "$tmp/destination", 'and it did not invent a destination' );
    like( $r->{said}, qr/nothing salvaged/, 'and says which of the three it was' );
};

subtest 'an empty salvage is a fetch that read nothing, and is not restored' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    make_path("$tmp/salvaged");
    tree( "$tmp/destination", 'keep.conf' => "live\n" );

    # This is what a directory the service keeps to itself comes back as: the
    # fetch runs as the admin user over sftp with no sudo, and says nothing.
    my $r = restore( "$tmp/salvaged", "$tmp/destination" );
    is( $r->{rc},                                0,        'not an error' );
    is( read_text("$tmp/destination/keep.conf"), "live\n", 'the destination is untouched' );
    like( $r->{said}, qr/empty/, 'and it says the salvage was empty' );
};

subtest 'a destination with state in it keeps it' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    tree( "$tmp/salvaged",    'db' => "partial copy\n" );
    tree( "$tmp/destination", 'db' => "the real thing\n" );

    # Re-provisioning a running guest: new_config fetched minutes ago, and if
    # that fetch was partial, writing it back would be the destructive half of
    # this whole feature.
    my $r = restore( "$tmp/salvaged", "$tmp/destination" );
    is( $r->{rc},                         0,                  'not an error' );
    is( read_text("$tmp/destination/db"), "the real thing\n", 'the live state is still there' );
    ok( -e "$tmp/salvaged/db", 'and the copy is left where somebody can look at it' );
};

subtest 'a rebuilt guest gets its state back' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    tree( "$tmp/salvaged/inner", 'zone.db' => "records\n" );

    my $r = restore( "$tmp/salvaged", "$tmp/destination" );
    is( $r->{rc},                                    0,           'restored' );
    is( read_text("$tmp/destination/inner/zone.db"), "records\n", 'contents and all' );
    ok( !-e "$tmp/salvaged", 'and it does not stay in two places' );
};

subtest 'an empty destination is filled rather than nested inside' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    tree( "$tmp/salvaged", 'dump.rdb' => "keys\n" );
    make_path("$tmp/destination");

    # mv onto an existing directory puts the source inside it, which is how a
    # restore ends up at /var/lib/redis/redis with the service still empty.
    my $r = restore( "$tmp/salvaged", "$tmp/destination" );
    is( $r->{rc}, 0, 'restored' );
    ok( -f "$tmp/destination/dump.rdb",  'the contents landed in the destination' );
    ok( !-d "$tmp/destination/salvaged", 'and not in a directory named after the copy' );
};

subtest 'a destination keeps the mode the recipe made it with' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    tree( "$tmp/salvaged", 'passwd' => "bob\n" );
    make_path("$tmp/destination");

    # cp -a src/. dst/ carries the attributes of src itself onto dst, and the
    # salvage arrives out of the domain directory the data target owns.  A mail
    # store the recipe had just made 2750 came back 0755, taking with it the
    # setgid bit that is what lets the next fetch read the maildirs at all.
    ## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
    chmod 02750, "$tmp/destination";
    chmod 00700, "$tmp/salvaged";

    my $r = restore( "$tmp/salvaged", "$tmp/destination" );
    is( $r->{rc},                                0,       'restored' );
    is( read_text("$tmp/destination/passwd"),    "bob\n", 'with the contents' );
    is( ( stat("$tmp/destination") )[2] & 07777, 02750,   'and the destination still has the mode it was made with' );
};

subtest 'a mode it was asked for still wins over the one it found' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    tree( "$tmp/salvaged", 'db' => "rows\n" );
    make_path("$tmp/destination");
    ## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
    chmod 02750, "$tmp/destination";

    # Preserving what was there is the default, not an override of the caller.
    #
    # On the permission bits alone: chmod leaves the setgid bit of a directory
    # alone whatever numeric mode it is given, so a caller cannot clear one this
    # way and this does not claim it can.
    my $r = restore( "$tmp/salvaged", "$tmp/destination", '', '0700' );
    is( $r->{rc},                                0,     'restored' );
    is( ( stat("$tmp/destination") )[2] & 00777, 00700, 'the mode the caller named is the one it ends up with' );
};

subtest 'a single file, and the ownership and mode it is asked for' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$tmp/salvaged", "signing key\n" );

    my $r = restore( "$tmp/salvaged", "$tmp/deeper/destination", '', '0600' );
    is( $r->{rc},                             0,               'restored' );
    is( read_text("$tmp/deeper/destination"), "signing key\n", 'through a directory that did not exist yet' );
    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    is( ( stat("$tmp/deeper/destination") )[2] & 07777, 0600, 'with the mode it was given' );
};

subtest 'it says what it wants when it is called wrong' => sub {
    my $r = restore();
    isnt( $r->{rc}, 0, 'no arguments is an error' );
    like( $r->{said}, qr/usage: restore_state/, 'and it says how it is called' );
};

done_testing();
