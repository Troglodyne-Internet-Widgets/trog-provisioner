#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-IPPool-DB.t - the address database of one hypervisor, and bin/ippool, which is how anything reaches it

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::NoWarnings qw{had_no_warnings};
use File::Temp();
use IPC::Run3();
use POSIX();
use Cpanel::JSON::XS();

use FindBin;
use FindBin::libs;
use Trog::SQLite();

use_ok('Provisioner::IPPool::DB');

my $IPPOOL = "$FindBin::Bin/../bin/ippool";

# A path for a database that is not there yet, in a directory of its own.
sub new_db () {
    Trog::SQLite::forget();
    return File::Temp::tempdir( CLEANUP => 1 ) . '/ips.db';
}

# What bin/ippool prints for $op on $db with @args, decoded, and its exit code.
sub ippool ( $input, @args ) {
    IPC::Run3::run3( [ $^X, $IPPOOL, @args ], \$input, \my $out, \my $err );
    my $code = $? >> 8;
    my $said = eval { Cpanel::JSON::XS->new->allow_nonref->decode( $out // q{} ) } // { unreadable => ( $out // q{} ) . ( $err // q{} ) };
    return ( $said, $code );
}

my %ASSIGN = ( bin => 'guests', nic => 'br0', main => 1, guest => 1, candidates => [qw{192.0.2.10 192.0.2.11 192.0.2.12}] );

subtest 'a database that is not there is refused, unless it is made on purpose' => sub {
    my $path = new_db();
    like( exception { Provisioner::IPPool::DB::run( $path, 'taken', {} ) }, qr/There[ ]is[ ]no[ ]address[ ]database[ ]at/, 'an empty one would give out addresses that guests use' );
    ok( !-e $path, 'and none is made' );

    is( Provisioner::IPPool::DB::run( $path, 'init', {} ), $path, 'init makes it' );
    is_deeply( Provisioner::IPPool::DB::run( $path, 'taken', {} ), {}, 'and then it answers' );

    my $other = new_db();
    is_deeply( Provisioner::IPPool::DB::run( $other, 'taken', {}, create => 1 ), {}, 'as does one that the caller lets it make' );
    like( exception { Provisioner::IPPool::DB::run( $other, 'drop_everything', {} ) }, qr/no[ ]operation[ ]'drop_everything'/, 'and an operation it does not have is refused' );
};

subtest 'assign: the first free address, once, and the same one again' => sub {
    my $path = new_db();
    Provisioner::IPPool::DB::run( $path, 'init' );
    Provisioner::IPPool::DB::run( $path, 'reserve', { ip => '192.0.2.10', name => 'gateway:192.0.2.10', nic => 'br0' } );

    is( Provisioner::IPPool::DB::run( $path, 'assign', { %ASSIGN, domain => 'a.test.test' } ), '192.0.2.11', 'a reservation is skipped' );
    is( Provisioner::IPPool::DB::run( $path, 'assign', { %ASSIGN, domain => 'a.test.test' } ), '192.0.2.11', 'a domain keeps what it has' );
    is( Provisioner::IPPool::DB::run( $path, 'assign', { %ASSIGN, domain => 'b.test.test' } ), '192.0.2.12', 'the next domain gets the next one' );
    like( exception { Provisioner::IPPool::DB::run( $path, 'assign', { %ASSIGN, domain => 'c.test.test' } ) }, qr/IP[ ]pool[ ]exhausted.*on[ ]br0/, 'and then the pool is empty' );

    is_deeply( Provisioner::IPPool::DB::run( $path, 'release', { domain => 'a.test.test' } ), { guests => '192.0.2.11' }, 'release says what it gave back' );
    is( Provisioner::IPPool::DB::run( $path, 'held_by', { domain => 'a.test.test', bin => 'guests' } ), undef, 'and it is gone' );
};

subtest 'two processes of bin/ippool on one database cannot give out one address twice' => sub {

    # The point of a database on each hypervisor: everything one assign does
    # happens in one process, in one transaction, on the machine that has the
    # file.  So this is processes, not a mock.
    my $path = new_db();
    Provisioner::IPPool::DB::run( $path, 'init' );
    Trog::SQLite::forget();
    my %args = ( %ASSIGN, candidates => [ map { "192.0.2.$_" } 10 .. 40 ] );

    pipe( my $read, my $write ) or die "pipe: $!";
    my @kids;
    foreach my $n ( 1 .. 6 ) {
        my $pid = fork() // die "fork: $!";
        if ( !$pid ) {
            close($read) or die "Could not close the reading end of the pipe: $!";
            my ($said) = ippool( Cpanel::JSON::XS::encode_json( { %args, domain => "d$n.test.test" } ), '--db', $path, 'assign' );
            print {$write} ( $said->{result} // 'ERROR: ' . Cpanel::JSON::XS::encode_json($said) ) . "\n";
            close($write) or die "Could not close the writing end of the pipe: $!";
            POSIX::_exit(0);
        }
        push @kids, $pid;
    }
    close($write) or die "Could not close the writing end of the pipe: $!";
    my @said = <$read>;
    close($read) or die "Could not close the reading end of the pipe: $!";
    waitpid( $_, 0 ) for @kids;
    chomp @said;

    is( scalar @said, 6, 'each process answered' );
    unlike( join( ',', @said ), qr/ERROR/, 'and none failed' ) or diag join( "\n", @said );
    my %seen;
    is_deeply( [ grep { $seen{$_}++ } @said ], [], 'and no address went out twice' ) or diag join( ',', sort @said );
    is( scalar keys %{ Provisioner::IPPool::DB::run( $path, 'taken' ) }, 6, 'and the database holds one row for each' );
};

subtest 'bin/ippool --db answers in JSON, a failure too' => sub {
    my $path = new_db();
    my ( $said, $code ) = ippool( q{}, '--db', $path, 'taken' );
    is( $code, 1, 'a database that is not there fails' );
    like( $said->{error}, qr/no[ ]address[ ]database/, 'and says why, in JSON, so the caller can tell it from no answer' );

    ( $said, $code ) = ippool( q{}, '--db', $path, 'check' );
    is( $code, 0, 'check answers without a database' );
    like( $said->{result}{perl}, qr/\A5[.]\d+[.]\d+\z/, 'with the version of perl' );

    ( $said, $code ) = ippool( q{}, '--db', $path, 'init' );
    is_deeply( [ $code, $said->{result} ], [ 0, $path ], 'init makes it' );

    ( $said, $code ) = ippool( '{"ip":"192.0.2.9","name":"hv:hv1","nic":"br0"}', '--db', $path, 'reserve' );
    is_deeply( [ $code, $said->{result} ], [ 0, 1 ], 'the arguments come on standard input' );
    ( $said, $code ) = ippool( q{}, '--db', $path, 'taken', '{}' );
    is_deeply( $said->{result}, { '192.0.2.9' => 'hv:hv1' }, 'or as the last argument' );
};

subtest 'seed and reseed: one transaction each, and a dry run writes nothing' => sub {
    my $path = new_db();
    Provisioner::IPPool::DB::run( $path, 'init' );
    my @rows = ( [qw{reserve 192.0.2.1 gateway:192.0.2.1 br0}], [ qw{record 192.0.2.10 a.test.test br0}, 1 ], [qw{reserve 192.0.2.10 insitu:unknown br0}] );

    is( Provisioner::IPPool::DB::run( $path, 'seed', { rows => \@rows, mark => ['hv:hv1'] } ), 2, 'each row it wrote, and not the reservation of an address that a guest holds' );
    is_deeply( Provisioner::IPPool::DB::run( $path, 'seeded' ), ['hv:hv1'], 'and the hypervisor is marked' );

    like( exception { Provisioner::IPPool::DB::run( $path, 'seed', { rows => [ [qw{reserve 192.0.2.2 gateway:x br0}], ['delete'] ], mark => ['hv:hv2'] } ) }, qr/no[ ]rows[ ]of[ ]the[ ]kind/, 'a row it does not know stops the seed' );
    is( Provisioner::IPPool::DB::run( $path, 'taken' )->{'192.0.2.2'}, undef, 'before anything of it is written' );

    my $dry = Provisioner::IPPool::DB::run( $path, 'reseed', { seeds => [], prune => [], dryrun => 1 } );
    is_deeply( [ $dry->{after}, $dry->{pruned} ], [ {}, 1 ], 'a dry reseed that prunes everything says so' );
    is( Provisioner::IPPool::DB::run( $path, 'held_by', { domain => 'a.test.test' } ), '192.0.2.10', 'and rolls it back' );
    is_deeply( Provisioner::IPPool::DB::run( $path, 'seeded' ), ['hv:hv1'], 'markers too' );

    my $real = Provisioner::IPPool::DB::run( $path, 'reseed', { seeds => [ { rows => [ $rows[0] ], mark => ['hv:hv1'] } ] } );
    is_deeply( $real->{after}, { '192.0.2.1' => 'gateway:192.0.2.1', '192.0.2.10' => 'a.test.test' }, 'a reseed keeps assignments and makes the reservations again' );
};

subtest 'migrate: rows from the old database, all or nothing' => sub {
    my $path = new_db();
    Provisioner::IPPool::DB::run( $path, 'init' );
    my @rows = (
        { ip => '192.0.2.10', domain => 'a.test.test', kind => 'domain',   bin => 'guests',     nic => 'br0', main => 1, assigned_at => '2026-01-01 00:00:00' },
        { ip => '10.8.0.130', domain => 'a.test.test', kind => 'domain',   bin => 'vpnclients', nic => q{},   main => 1, assigned_at => undef },
        { ip => '192.0.2.1',  domain => 'gateway:x',   kind => 'reserved', bin => 'guests',     nic => 'br0', main => 1, assigned_at => undef },
    );

    is_deeply( Provisioner::IPPool::DB::run( $path, 'migrate', { rows => \@rows, dryrun => 1 } ), { added => 3, kept => 0 }, 'a dry run counts' );
    is_deeply( Provisioner::IPPool::DB::run( $path, 'taken' ),                                    {},                        'and writes nothing' );
    is_deeply( Provisioner::IPPool::DB::run( $path, 'migrate', { rows => \@rows } ),              { added => 3, kept => 0 }, 'a real one writes each row' );
    is_deeply( Provisioner::IPPool::DB::run( $path, 'migrate', { rows => \@rows } ),              { added => 0, kept => 3 }, 'and a second one finds them there' );

    my $other = { %{ $rows[0] }, ip     => '192.0.2.11', domain => 'b.test.test' };
    my $clash = { %{ $rows[0] }, domain => 'c.test.test' };
    like( exception { Provisioner::IPPool::DB::run( $path, 'migrate', { rows => [ $other, $clash ] } ) }, qr/192[.]0[.]2[.]10[ ]is[ ]a[.]test[.]test.*c[.]test[.]test/, 'an address with another holder stops it' );
    is( Provisioner::IPPool::DB::run( $path, 'taken' )->{'192.0.2.11'}, undef, 'and nothing of it is written' );
};

had_no_warnings();
done_testing();
