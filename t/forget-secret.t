#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/forget-secret.t - taking a secret out of the store, and refusing to take out
one that is still wanted

=cut

use Test::More;
use Capture::Tiny qw{capture_stdout capture_stderr};
use Test::Fatal   qw{exception};
use File::Temp    qw{tempdir};

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use File::Slurper::Temp();

use Provisioner::Cookbook();
use Trog::Credentials();
use Trog::Secrets();

my $script = "$FindBin::Bin/../bin/forget_secret";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

File::Slurper::Temp::write_text(
    "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml",
    "---\n_base:\n  _global:\n    install_dir: /opt/domains\nexample.test:\n  ntp:\n"
);
Provisioner::Cookbook->forget();
Trog::Credentials->remember( 'keepass', 'pw' );

sub store {
    my $file = tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    Trog::Secrets->create(
        $file, 'pw',
        'secret:guests/example.test/password' => 'the key of a guest that exists',
        'secret:old/retired/password'         => 'nothing reads this',
    );
    return $file;
}

subtest 'a secret nothing asks for is removed' => sub {
    my $file = store();

    my ( $said, $rc ) = capture_stdout { Provisioner::Bin::forget_secret::main( qw{--group old --title retired --secrets}, $file ) };
    is( $rc, 0, 'it says it worked' );
    like( $said, qr/Removed[ ]old\/retired/, 'and which entry went' );

    like( exception { Trog::Secrets->lookup( $file, 'pw', probe => 'secret:old/retired/password' ) }, qr/No[ ]entry[ ]'retired'/, 'and it is gone from the store' );

    # The neighbour is the whole point of not rewriting the file wholesale.
    my %held = Trog::Secrets->lookup( $file, 'pw', probe => 'secret:guests/example.test/password' );
    is( $held{probe}, 'the key of a guest that exists', 'while the rest of the store is untouched' );
};

subtest 'a secret this installation still asks for is refused' => sub {
    my $file = store();

    my ( $warned, $rc ) = capture_stderr { Provisioner::Bin::forget_secret::main( qw{--group guests --title example.test --secrets}, $file ) };
    is( $rc, 1, 'it refuses' );
    like( $warned, qr/still[ ]asks[ ]for[ ]secret:guests\/example\.test/, 'naming the reference that wants it' );
    like( $warned, qr/--force/,                                           'and how to mean it anyway' );

    my %held = Trog::Secrets->lookup( $file, 'pw', probe => 'secret:guests/example.test/password' );
    is( $held{probe}, 'the key of a guest that exists', 'and the secret is still there' );
};

subtest '--force means it anyway' => sub {
    my $file = store();

    my ( $said, $rc ) = capture_stdout { Provisioner::Bin::forget_secret::main( qw{--group guests --title example.test --secrets}, $file, '--force' ) };
    is( $rc, 0, 'it goes ahead' );
    like( $said, qr/Removed[ ]guests\/example\.test/, 'and says so' );

    like( exception { Trog::Secrets->lookup( $file, 'pw', probe => 'secret:guests/example.test/password' ) }, qr/No[ ]entry/, 'the entry is gone' );
};

subtest 'asking for what is not there is not an error' => sub {
    my $file = store();

    my ( $said, $rc ) = capture_stdout { Provisioner::Bin::forget_secret::main( qw{--group nosuch --title thing --secrets}, $file ) };
    is( $rc, 0, 'because the point of asking is to end with it gone' );
    like( $said, qr/nothing[ ]to[ ]remove/, 'and it says that is what happened' );
};

done_testing();
