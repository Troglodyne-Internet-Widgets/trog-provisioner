#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Trog-Secrets.t - finding the notes a config leaves, and putting the answers back

=cut

use Test::More;
use File::Temp qw{tempdir};

use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Trog::Secrets();

subtest 'a reference names a group, an entry and a field' => sub {
    is_deeply(
        [ Trog::Secrets->parse('secret:group/entry/password') ],
        [qw{group entry password}], 'in that order'
    );

    foreach my $bad ( qw{nope/entry/password secret:group/entry secret: secret:a//c}, undef ) {
        eval { Trog::Secrets->parse($bad) };
        like( $@, qr/Malformed secret/, "'" . ( $bad // 'undef' ) . "' is refused" );
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

subtest 'write() then read() is a round trip' => sub {
    my $file = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';

    Trog::Secrets->write(
        $file, 'hunter2',
        'secret:a/b/password' => 'the password',
        'secret:a/b/username' => 'the user',
        'secret:c/d/password' => 'another',
    );
    ok( -f $file, 'a database got written' );    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)

    my %values = Trog::Secrets->read(
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

subtest 'read() says which part it could not find' => sub {
    my $file = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    Trog::Secrets->write( $file, 'hunter2', 'secret:a/b/password' => 'the password' );

    # A reference that resolved to nothing would otherwise arrive on a guest as
    # an empty password, which is worse than not provisioning.
    eval { Trog::Secrets->read( $file, 'hunter2', p => 'secret:nope/b/password' ) };
    like( $@, qr/No group 'nope'/, 'a group that is not there' );

    eval { Trog::Secrets->read( $file, 'hunter2', p => 'secret:a/nope/password' ) };
    like( $@, qr/No entry 'nope' in group 'a'/, 'an entry that is not there' );

    eval { Trog::Secrets->read( $file, 'hunter2', p => 'secret:a/b/username' ) };
    like( $@, qr/has no username/, 'a field that was never set' );

    eval { Trog::Secrets->read( $file, 'wrong password', p => 'secret:a/b/password' ) };
    isnt( $@, '', 'and a password that does not open it' );
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
    is( $config->{_base}{_global}{registrar}{type}, 'easydns',       'leaving its neighbours alone' );
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

    local $ran = 0;
    my $config = { a => { b => 'note' } };
    eval { Trog::Secrets->apply( $config, "a/$evil" => 'value' ) };

    is( $ran, 0, 'nothing in the path was executed' );

    # It is a key, and a silly one, and that is all it is.
    is( $config->{a}{$evil}, 'value', 'it was taken for the literal key it is' );
    is( $config->{a}{b},     'note',  'and nothing else was disturbed' );
};

subtest 'apply() refuses a path that leads nowhere' => sub {
    eval { Trog::Secrets->apply( { a => 'not a ref' }, 'a/b/c' => 'value' ) };
    like( $@, qr/Could not follow 'a\/b\/c'/, 'rather than autovivifying its way through' );
};

subtest 'the whole cycle, as new_config runs it' => sub {
    my $file   = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    my $config = { recipe => { key => 'secret:g/e/password', other => 'left alone' } };

    Trog::Secrets->write( $file, 'pw', 'secret:g/e/password' => 'the real thing' );

    my %needed = Trog::Secrets->needed($config);
    my %values = Trog::Secrets->read( $file, 'pw', %needed );
    Trog::Secrets->apply( $config, %values );

    is( $config->{recipe}{key},   'the real thing', 'the note became the password' );
    is( $config->{recipe}{other}, 'left alone',     'and nothing else moved' );
};

subtest 'remember makes a secret once and keeps it' => sub {
    my $dir  = File::Temp::tempdir( CLEANUP => 1 );
    my $file = "$dir/secrets.kdbx";
    my $pass = 'throwaway';

    Trog::Secrets->write( $file, $pass, 'secret:existing/entry/password' => 'written by somebody' );

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
    my %read = Trog::Secrets->read( $file, $pass, 'somewhere' => 'secret:matrix/vm.test-signing-key/password' );
    is( $read{somewhere}, 'made-1', 'and read() finds it like any other entry' );

    eval {
        Trog::Secrets->remember( $file, $pass, 'secret:empty/handed/password' => sub { '' } );
    };
    like( $@, qr/produced nothing/, 'a generator that makes nothing is an error rather than an empty secret' );

    is_deeply( { Trog::Secrets->remember( $file, $pass ) }, {}, 'nothing asked for is nothing done' );

    # The database keeps password and username and drops anything else, so a
    # reference naming another field would store nothing, be answered from
    # memory this run, and be made afresh on every run after -- which is the one
    # failure this whole mechanism exists to prevent.
    eval {
        Trog::Secrets->remember( $file, $pass, 'secret:matrix/vm.test/signing_key' => sub { 'not a field it keeps' } );
    };
    like( $@, qr/did not keep/,         'a field the database drops is an error at once' );
    like( $@, qr/password or username/, 'and it says which fields there are' );
};

done_testing();
