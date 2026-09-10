#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Trog-GuestKey.t - where a guest's key is kept, and what happens when it is not
where it used to be

=cut

use Test::More;
use Test::NoWarnings;
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();

use FindBin::libs;

# Never the installation's real store: what these assert on must not depend on
# what is deployed on the machine running them.
## no critic (CompileTime) -- setting it at compile time is the point
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Trog::Config();
use Trog::GuestKey();

my $DOMAIN = 'vm.test.test';
my $KEY    = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----";

subtest 'the reference is keyed on the domain' => sub {

    # One entry per guest: two domains must not answer to each other's key, and
    # a group of its own keeps them out of the way of what an operator wrote.
    is( Trog::GuestKey->ref_for($DOMAIN), 'secret:guests/vm.test.test/password', 'named for the domain' );
    isnt( Trog::GuestKey->ref_for('other.test.test'), Trog::GuestKey->ref_for($DOMAIN), 'and no two share one' );
};

subtest 'a key still on disk is the one used, and nothing is asked for' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/key.rsa", "$KEY\n" );

    # An installation whose domains were provisioned before this existed keeps
    # working, and seals itself one domain at a time as each is rebuilt.  If it
    # did not, every one of them would be unreachable until it was.
    my $creds = Test::MockModule->new('Trog::Credentials');
    $creds->redefine( prompt => sub { die "asked for a password when the key was on disk\n" } );

    is( Trog::GuestKey->path( $DOMAIN, "$dir/key.rsa" ), "$dir/key.rsa", 'the file is the answer' );
};

subtest 'no store means no key and no prompt' => sub {

    # The failure this is really about is a wait, not a refusal.  A prompt in a
    # run with nobody to type at hangs until something kills it, and that is how
    # the suite behaved the first time this was wired up: every test that
    # reached for a key sat waiting on a password for a database that was not
    # there.
    my $creds = Test::MockModule->new('Trog::Credentials');
    $creds->redefine( prompt => sub { die "asked for a password with no store to open\n" } );

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- asserting the store is absent, which is the case under test
    ok( !-f Trog::Config->path('secrets.kdbx'), 'there is no store in this configuration' );
    is( Trog::GuestKey->path( $DOMAIN, "/bogus/nothing/key.rsa" ), undef, 'so there is no key, and nothing was asked' );
};

subtest 'sealing puts it in the store and takes it off the disk' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/key.rsa", "$KEY\n" );

    my ( %written, $asked );
    my $creds = Test::MockModule->new('Trog::Credentials');
    $creds->redefine( prompt => sub { $asked++; return 'hunter2' } );
    my $secrets = Test::MockModule->new('Trog::Secrets');
    $secrets->redefine( write => sub { my ( undef, undef, undef, %v ) = @_; %written = %v; return 1 } );

    ok( Trog::GuestKey->seal( $DOMAIN, "$dir/key.rsa" ), 'it seals' );
    is( $written{ Trog::GuestKey->ref_for($DOMAIN) }, "$KEY\n", 'the whole key went in, newlines and all' );
    ok( !-e "$dir/key.rsa", 'and the file is gone' );

    # write rather than remember: the key is rotated on every real provision, so
    # the store has to hold the current one.  remember keeps the first answer
    # forever, which would quietly turn a per-provision key into a standing one.
    is( $asked, 1, 'the password was wanted once' );
};

subtest 'sealing nothing is not sealing' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my $secrets = Test::MockModule->new('Trog::Secrets');
    $secrets->redefine( write => sub { die "wrote an empty key into the store\n" } );

    # A dry run leaves no key to seal, and a domain that has never been built
    # has none either.  Writing an empty value would be worse than doing
    # nothing: the store would then answer with it.
    ok( !Trog::GuestKey->seal( $DOMAIN, "$dir/nothing-here" ), 'a key that is not there does not get sealed' );
};

subtest 'a sealed key is fetched once and lands somewhere private' => sub {
    my $store = Trog::Config->path('secrets.kdbx');
    File::Slurper::Temp::write_binary( $store, 'pretend this is a kdbx' );

    my $reads = 0;
    my $creds = Test::MockModule->new('Trog::Credentials');
    $creds->redefine( prompt => sub { return 'hunter2' } );
    my $secrets = Test::MockModule->new('Trog::Secrets');
    $secrets->redefine( read => sub { $reads++; return ( key => $KEY ) } );

    my $path = Trog::GuestKey->path( 'fetched.test.test', '/bogus/nothing/key.rsa' );
    ok( defined $path, 'a path comes back' ) or return;

    is( File::Slurper::read_text($path), "$KEY\n", 'holding the key, with the trailing newline ssh wants' );

    # 0600, because this is the credential for a machine and it is now sitting
    # in a world-readable directory.
    my @stat = stat($path);
    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    is( sprintf( '%04o', $stat[2] & 07777 ), '0600', 'readable by nobody else' );

    # Asked for twice in a run it is fetched once: every guest this touches
    # would otherwise mean another decryption of the database.
    Trog::GuestKey->path( 'fetched.test.test', '/bogus/nothing/key.rsa' );
    is( $reads, 1, 'and the store was opened once' );

    unlink $store;
};

Test::NoWarnings::had_no_warnings();

done_testing;
