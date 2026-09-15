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
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Test::More;
use Test::Fatal qw{exception};
use File::Temp();
use IPC::Run3();
use Trog::Secrets();
use Trog::Credentials();

require_ok("$FindBin::Bin/../bin/add_secret") or die "could not require SUT: $@";

sub store {
    my $dir  = File::Temp::tempdir( CLEANUP => 1 );
    my $kdbx = "$dir/secrets.kdbx";

    # Something already in it, so this is a store being added to rather than made.
    Trog::Secrets->create( $kdbx, 'throwaway', 'secret:seed/entry/password' => 'already here' );
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

    my $rc = add( '--secrets', $kdbx, qw{--group troglodyne --title easydns_token -- hunter2} );
    is( $rc, 0, 'it reports success' );

    my %got = Trog::Secrets->lookup( $kdbx, 'throwaway', probe => 'secret:troglodyne/easydns_token/password' );
    is( $got{probe}, 'hunter2', 'and the store holds it' );

    # The one that was there before is still there: saving rewrites the whole
    # database, and every other domain is provisioned out of the same file.
    my %seed = Trog::Secrets->lookup( $kdbx, 'throwaway', probe => 'secret:seed/entry/password' );
    is( $seed{probe}, 'already here', 'without disturbing what was already in it' );
};

subtest 'the field defaults to password, and username works too' => sub {
    my $kdbx = store();

    is( add( '--secrets', $kdbx, qw{--group troglodyne --title tok --field username -- someuser} ), 0, 'a username is stored' );
    my %got = Trog::Secrets->lookup( $kdbx, 'throwaway', probe => 'secret:troglodyne/tok/username' );
    is( $got{probe}, 'someuser', 'under the field it was given' );
};

# The case this was added for: a private key does not go on a command line.  An
# argument is readable out of the process table for as long as the run lasts, and
# it lands in the shell history of whoever typed it.
subtest 'a value read from standard input' => sub {
    my $kdbx = store();
    my $key  = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END OPENSSH PRIVATE KEY-----\n";

    my $fh = File::Temp->new();
    print {$fh} $key;
    close($fh) or die 'Could not close ' . $fh->filename . ": $!";

    my $rc = do {
        open( local *STDIN, '<', $fh->filename ) or die "could not point stdin at the key: $!";
        add( '--secrets', $kdbx, qw{--group koan --title bot-github-ssh --stdin} );
    };
    is( $rc, 0, 'it reports success' );

    # One trailing newline off, and not one of the interior ones -- which are the
    # key.  This is what "$(cat file)" would have given, and what the recipe that
    # generates one stores.
    my %got  = Trog::Secrets->lookup( $kdbx, 'throwaway', probe => 'secret:koan/bot-github-ssh/password' );
    my $want = $key;
    chomp $want;
    is( $got{probe}, $want, 'the whole key went in, interior newlines and all' );
    unlike( $got{probe}, qr/\n\z/, 'without the trailing newline' );
};

# The run that found this: nothing handed in, so the passphrase is really asked
# for -- and standard input, the key, is already read to the end.  Asked there,
# the prompt got undef and died on a warning about it.
subtest 'with --stdin the passphrase is asked at the terminal, not of the spent pipe' => sub {
    my $kdbx = store();
    my $key  = "-----BEGIN OPENSSH PRIVATE KEY-----\nc2Vjb25kIGtleQ==\n-----END OPENSSH PRIVATE KEY-----\n";

    my $keyfile = File::Temp->new();
    print {$keyfile} $key;
    close($keyfile) or die 'Could not close ' . $keyfile->filename . ": $!";

    # A file standing in for /dev/tty, holding the passphrase somebody typed.
    my $tty = File::Temp->new();
    print {$tty} "throwaway\n";
    close($tty) or die 'Could not close ' . $tty->filename . ": $!";

    Trog::Credentials->forget();
    my $rc = do {
        local $Trog::Credentials::TERMINAL = $tty->filename;
        open( local *STDIN, '<', $keyfile->filename ) or die "could not point stdin at the key: $!";
        Provisioner::Bin::add_secret::main( '--secrets', $kdbx, qw{--group koan --title asked-github-ssh --stdin} );
    };
    is( $rc, 0, 'it reports success' );

    my %got  = Trog::Secrets->lookup( $kdbx, 'throwaway', probe => 'secret:koan/asked-github-ssh/password' );
    my $want = $key;
    chomp $want;
    is( $got{probe}, $want, 'the key went in, under the passphrase typed at the terminal' );

    # And with no terminal, a sentence saying so rather than a crash.
    Trog::Credentials->forget();
    my $why = do {
        local $Trog::Credentials::TERMINAL = '/bogus/tty';
        open( local *STDIN, '<', $keyfile->filename ) or die "could not point stdin at the key: $!";
        exception { Provisioner::Bin::add_secret::main( '--secrets', $kdbx, qw{--group koan --title unasked-github-ssh --stdin} ) };
    };
    like( $why, qr{Cannot ask for keepass at a terminal: /bogus/tty}, 'no terminal is refused, naming it' );

    my %none = eval { Trog::Secrets->lookup( $kdbx, 'throwaway', probe => 'secret:koan/unasked-github-ssh/password' ) };
    ok( !defined $none{probe}, 'and nothing was stored' );
};

# pod2usage exits rather than dying, so these have to be real runs -- the same
# reason t/provision.t and t/destroy.t run their scripts for a usage path.
# Neither refusal reaches the passphrase: both fire before Trog::Credentials is
# asked for anything.
sub run_add {
    my ( $stdin, @args ) = @_;
    my $out = q{};
    IPC::Run3::run3( [ $^X, "$FindBin::Bin/../bin/add_secret", @args ], $stdin, \$out, \$out );
    return ( $?, $out );
}

subtest 'standard input and a value on the command line is refused' => sub {
    my $kdbx = store();

    # Two answers to one question.  Picking one quietly is how the wrong secret
    # gets stored, so this exits on the usage rather than choosing.
    my ( $rc, $out ) = run_add( \"from the pipe\n", '--secrets', $kdbx, qw{--group t --title both --stdin -- fromtheargv} );
    isnt( $rc, 0, 'it exits non-zero' );
    like( $out, qr/not both/, 'saying it will not pick one' );

    my %got = eval { Trog::Secrets->lookup( $kdbx, 'throwaway', probe => 'secret:t/both/password' ) };
    ok( !defined $got{probe}, 'and nothing was stored either way' );
};

subtest 'an empty standard input is no value at all' => sub {
    my $kdbx = store();

    # An empty secret is worse than none: the reference would resolve, and
    # whatever authenticated with it fails somewhere far from here.
    my ( $rc, $out ) = run_add( \undef, '--secrets', $kdbx, qw{--group t --title empty --stdin} );
    isnt( $rc, 0, 'it exits non-zero' );
    like( $out, qr/Need a value/, 'saying there was nothing to store' );

    my %got = eval { Trog::Secrets->lookup( $kdbx, 'throwaway', probe => 'secret:t/empty/password' ) };
    ok( !defined $got{probe}, 'and stored nothing' );
};

subtest 'a reference that already holds something is left alone' => sub {
    my $kdbx = store();

    # The same value is not a change, so it is not a failure either.
    is( add( '--secrets', $kdbx, qw{--group seed --title entry --}, 'already here' ), 0, 'storing what is already there is fine' );

    # A different one is refused rather than rotated: whatever authenticated
    # with the old secret stops working, and that is not a thing to do while
    # adding a missing entry.
    my $rc;
    my @said;
    {
        local $SIG{__WARN__} = sub { push @said, @_ };
        $rc = add( '--secrets', $kdbx, qw{--group seed --title entry --}, 'something else' );
    }
    isnt( $rc, 0, 'a different value is refused' );
    like( join( '', @said ), qr/will not replace it/, 'and says why' );

    my %got = Trog::Secrets->lookup( $kdbx, 'throwaway', probe => 'secret:seed/entry/password' );
    is( $got{probe}, 'already here', 'leaving the store as it was' );
};

subtest 'a field the database does not keep is an error, not a success' => sub {
    my $kdbx = store();

    # KeePass keeps password and username; anything else is dropped on save,
    # and a tool that reported success would have written nothing.
    my $rc = eval { add( '--secrets', $kdbx, qw{--group g --title t --field notes -- value} ) };
    is( $rc, undef, 'it dies rather than returning' );
    like( $@, qr/password or username/, 'naming the fields that are kept' ) or diag $@;
};

done_testing();
