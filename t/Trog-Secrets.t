#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Trog-Secrets.t - finding the notes a config leaves, and putting the answers back

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Trog::Secrets();

subtest 'a reference names a group, an entry and a field' => sub {
    is_deeply(
        [ Trog::Secrets->parse('secret:group/entry/password') ],
        [qw{group entry password}], 'in that order'
    );

    foreach my $bad ( qw{nope/entry/password secret:group/entry secret: secret:a//c}, undef ) {
        like( exception { Trog::Secrets->parse($bad) }, qr/Malformed[ ]secret/, "'" . ( $bad // 'undef' ) . "' is refused" );
    }
};

subtest 'needed() finds them wherever they are' => sub {
    my %found = Trog::Secrets->needed(
        {
            _base => { _global => { registrar => { key => 'secret:a/b/password', type => 'easydns' } } },
            list  => [ 'plain', { deep => 'secret:c/d/username' } ],
            plain => 'nothing here',
            empty => undef,
        }
    );

    is_deeply(
        \%found,
        {
            '_base/_global/registrar/key' => 'secret:a/b/password',
            'list/1/deep'                 => 'secret:c/d/username',
        },
        'through hashes, arrays and past everything else'
    );

    # The path is how apply() finds its way back, so an array index has to come
    # through as one.
    ok( exists $found{'list/1/deep'}, 'array indices are part of the path' );

    is_deeply( { Trog::Secrets->needed( {} ) },  {}, 'nothing in an empty config' );
    is_deeply( { Trog::Secrets->needed(undef) }, {}, 'nor in one that is not there' );
};

subtest 'create() then lookup() is a round trip' => sub {
    my $file = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';

    Trog::Secrets->create(
        $file, 'hunter2',
        'secret:a/b/password' => 'the password',
        'secret:a/b/username' => 'the user',
        'secret:c/d/password' => 'another',
    );
    ok( -f $file, 'a database got written' );    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)

    my %values = Trog::Secrets->lookup(
        $file, 'hunter2',
        'where/it/was' => 'secret:a/b/password',
        'and/here'     => 'secret:a/b/username',
        'over/there'   => 'secret:c/d/password',
    );

    is_deeply(
        \%values,
        {
            'where/it/was' => 'the password',
            'and/here'     => 'the user',
            'over/there'   => 'another',
        },
        'keyed by where the reference was, not by the reference'
    );
};

subtest 'replace() sets what it names and leaves the rest of the store alone' => sub {
    my $file = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    my $pass = 'throwaway';

    Trog::Secrets->create(
        $file, $pass,
        'secret:registrar/easydns/password' => 'REGISTRAR',
        'secret:guests/vm.test/password'    => 'the old key',
    );

    ok( Trog::Secrets->replace( $file, $pass, 'secret:guests/vm.test/password' => 'the new key' ), 'it replaces' );

    my %after = Trog::Secrets->lookup(
        $file, $pass,
        key       => 'secret:guests/vm.test/password',
        registrar => 'secret:registrar/easydns/password',
    );
    is( $after{key}, 'the new key', 'the field it named holds the new value' );

    # The whole reason this exists rather than create().  create() builds a
    # fresh database out of what it is handed, so against a real store it would
    # leave it holding one entry and nothing else.
    is( $after{registrar}, 'REGISTRAR', 'and every other secret in the database survived' );

    # A reference with nothing behind it yet is added rather than refused: a
    # guest being sealed for the first time has no entry to overwrite.
    ok( Trog::Secrets->replace( $file, $pass, 'secret:guests/new.test/password' => 'minted' ), 'a new reference is added' );
    my %fresh = Trog::Secrets->lookup( $file, $pass, k => 'secret:guests/new.test/password' );
    is( $fresh{k}, 'minted', 'and comes back out' );

    is( Trog::Secrets->replace( $file, $pass ), 0, 'nothing asked for is nothing done' );
};

subtest 'lookup() says which part it could not find' => sub {
    my $file = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    Trog::Secrets->create( $file, 'hunter2', 'secret:a/b/password' => 'the password' );

    # A reference that resolved to nothing would otherwise arrive on a guest as
    # an empty password, which is worse than not provisioning.
    like( exception { Trog::Secrets->lookup( $file, 'hunter2',        p => 'secret:nope/b/password' ) }, qr/No[ ]group[ ]'nope'/,                    'a group that is not there' );
    like( exception { Trog::Secrets->lookup( $file, 'hunter2',        p => 'secret:a/nope/password' ) }, qr/No[ ]entry[ ]'nope'[ ]in[ ]group[ ]'a'/, 'an entry that is not there' );
    like( exception { Trog::Secrets->lookup( $file, 'hunter2',        p => 'secret:a/b/username' ) },    qr/has[ ]no[ ]username/,                    'a field that was never set' );
    isnt( exception { Trog::Secrets->lookup( $file, 'wrong password', p => 'secret:a/b/password' ) }, undef, 'and a password that does not open it' );
};

subtest 'apply() puts them back where the notes were' => sub {
    my $config = {
        _base => { _global => { registrar => { key => 'secret:a/b/password', type => 'easydns' } } },
        list  => [ 'plain', { deep => 'secret:c/d/username' } ],
    };

    Trog::Secrets->apply(
        $config,
        '_base/_global/registrar/key' => 'resolved',
        'list/1/deep'                 => 'also resolved',
    );

    is( $config->{_base}{_global}{registrar}{key},  'resolved',      'into a nested hash' );
    is( $config->{list}[1]{deep},                   'also resolved', 'and through an array index' );
    is( $config->{_base}{_global}{registrar}{type}, 'easydns',       'leaving its neighbors alone' );
};

our $ran = 0;
sub pwned { $ran++; return 1 }

subtest 'apply() walks the path rather than eval-ing it' => sub {

    # This used to assemble the whole assignment as a string and eval it, with
    # each path component pasted between single quotes.  A component carrying a
    # quote therefore closed it and ran whatever came next -- and the path comes
    # out of somebody's configuration file.
    # Built up piecewise: the payload carries the braces and quotes that would
    # otherwise end whatever delimiter this was written with.
    my $evil = join q{}, "a'", '};', ' main::pwned(); ', '$x->{', "'b";

    $ran = 0;
    my $config = { a => { b => 'note' } };
    is( exception { Trog::Secrets->apply( $config, "a/$evil" => 'value' ) }, undef, 'applying it does not die' );

    is( $ran, 0, 'nothing in the path was executed' );

    # It is a key, and a silly one, and that is all it is.
    is( $config->{a}{$evil}, 'value', 'it was taken for the literal key it is' );
    is( $config->{a}{b},     'note',  'and nothing else was disturbed' );
};

subtest 'apply() refuses a path that leads nowhere' => sub {
    like( exception { Trog::Secrets->apply( { a => 'not a ref' }, 'a/b/c' => 'value' ) }, qr/Could[ ]not[ ]follow[ ]'a\/b\/c'/, 'rather than autovivifying its way through' );
};

subtest 'the whole cycle, as new_config runs it' => sub {
    my $file   = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    my $config = { recipe => { key => 'secret:g/e/password', other => 'left alone' } };

    Trog::Secrets->create( $file, 'pw', 'secret:g/e/password' => 'the real thing' );

    my %needed = Trog::Secrets->needed($config);
    my %values = Trog::Secrets->lookup( $file, 'pw', %needed );
    Trog::Secrets->apply( $config, %values );

    is( $config->{recipe}{key},   'the real thing', 'the note became the password' );
    is( $config->{recipe}{other}, 'left alone',     'and nothing else moved' );
};

subtest 'remember makes a secret once and keeps it' => sub {
    my $dir  = File::Temp::tempdir( CLEANUP => 1 );
    my $file = "$dir/secrets.kdbx";
    my $pass = 'throwaway';

    Trog::Secrets->create( $file, $pass, 'secret:existing/entry/password' => 'written by somebody' );

    my $calls = 0;
    my $make  = sub { $calls++; return "made-$calls" };

    my %first = Trog::Secrets->remember( $file, $pass, 'secret:matrix/vm.test-signing-key/password' => $make );
    is( $first{'secret:matrix/vm.test-signing-key/password'}, 'made-1', 'a reference that held nothing gets one made' );
    is( $calls,                                               1,        'the generator ran once' );

    # A new process, the same database: the point of the whole thing.
    my %again = Trog::Secrets->remember( $file, $pass, 'secret:matrix/vm.test-signing-key/password' => $make );
    is( $again{'secret:matrix/vm.test-signing-key/password'}, 'made-1', 'and the next run is answered with the same one' );
    is( $calls,                                               1,        'without the generator running again' );

    my %kept = Trog::Secrets->remember( $file, $pass, 'secret:existing/entry/password' => sub { 'replaced' } );
    is( $kept{'secret:existing/entry/password'}, 'written by somebody', 'what an operator wrote down is answered, never replaced' );

    # Reading it the ordinary way has to find what remember left.
    my %read = Trog::Secrets->lookup( $file, $pass, 'somewhere' => 'secret:matrix/vm.test-signing-key/password' );
    is( $read{somewhere}, 'made-1', 'and lookup() finds it like any other entry' );

    like(
        exception {
            Trog::Secrets->remember( $file, $pass, 'secret:empty/handed/password' => sub { '' } )
        },
        qr/produced[ ]nothing/,
        'a generator that makes nothing is an error rather than an empty secret'
    );

    is_deeply( { Trog::Secrets->remember( $file, $pass ) }, {}, 'nothing asked for is nothing done' );

    # The database keeps password and username and drops anything else, so a
    # reference naming another field would store nothing, be answered from
    # memory this run, and be made afresh on every run after -- which is the one
    # failure this whole mechanism exists to prevent.
    my $err = exception {
        Trog::Secrets->remember( $file, $pass, 'secret:matrix/vm.test/signing_key' => sub { 'not a field it keeps' } )
    };
    like( $err, qr/did[ ]not[ ]keep/,         'a field the database drops is an error at once' );
    like( $err, qr/password[ ]or[ ]username/, 'and it says which fields there are' );
};

done_testing();
