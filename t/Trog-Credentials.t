#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Trog-Credentials.t - passwords handed to a run that has nobody to ask

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use IO::String;

use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Trog::Credentials();

sub load_block {
    my ($block) = @_;
    Trog::Credentials->forget();
    Trog::Credentials->load( IO::String->new($block) );
    return;
}

subtest 'what a block says' => sub {
    load_block("keepass: correct horse battery staple\nsudo: hunter2\n");

    is( Trog::Credentials->get('keepass'), 'correct horse battery staple', 'the passphrase' );
    is( Trog::Credentials->get('sudo'),    'hunter2',                      'and the sudo password' );
    is( Trog::Credentials->have('sudo'),   1,                              'both are there' );

    # Not given is not the same as given empty, and the difference is whether
    # anybody gets prompted.
    load_block("keepass: only this one\n");
    is( Trog::Credentials->have('sudo'), 0,     'a name not given is not there' );
    is( Trog::Credentials->get('sudo'),  undef, 'and reads as nothing' );

    load_block("sudo:\n");
    is( Trog::Credentials->have('sudo'), 1,  'a name given empty is there' );
    is( Trog::Credentials->get('sudo'),  '', 'and is empty rather than missing' );
};

subtest 'what a password is allowed to be' => sub {

    # Exactly one space after the colon is the separator; everything after it is
    # the password, whatever it looks like.
    load_block("sudo:  two spaces, so one leading\n");
    is( Trog::Credentials->get('sudo'), ' two spaces, so one leading', 'leading whitespace survives' );

    load_block("sudo: trailing space \n");
    is( Trog::Credentials->get('sudo'), 'trailing space ', 'and trailing' );

    load_block("sudo: has: a colon: in it\n");
    is( Trog::Credentials->get('sudo'), 'has: a colon: in it', 'a colon in the password is just a colon' );

    load_block("keepass: correct horse\n\nsudo: never read\n");
    is( Trog::Credentials->have('sudo'), 0, 'a blank line ends the block' );
};

subtest 'a name it does not know is an error, not a shrug' => sub {

    # The failure this prevents: a misspelling that quietly means "prompt for
    # it", on a run with no terminal, which hangs or dies minutes later.
    like(
        exception { load_block("keypass: mistyped\n") },
        qr/Unknown[ ]credential[ ]'keypass'/,
        'a misspelled name is refused'
    );
    like( exception { load_block("keypass: mistyped\n") }, qr/keepass,[ ]sudo/, 'and it says what the names are' );

    like(
        exception { load_block("just a bare password\n") },
        qr/Expected[ ]'name:[ ]value'/,
        'and so is a bare line, which is what an older caller would have sent'
    );
};

subtest 'nothing is read unless something asks' => sub {

    # The reason this is not automatic.  An earlier version read standard input
    # whenever it did not look like a terminal, which hangs forever on a caller
    # that is not a terminal, meant to hand over nothing, and never closes its
    # end -- this test harness, for one.  A test that asks for a credential
    # nobody loaded has to answer immediately.
    Trog::Credentials->forget();
    is( Trog::Credentials->have('keepass'), 0,     'nothing loaded is nothing held' );
    is( Trog::Credentials->have('sudo'),    0,     'for either of them' );
    is( Trog::Credentials->get('sudo'),     undef, 'and nothing to give back' );
};

subtest 'who actually asks' => sub {
    my $asked = 0;
    my $mock  = Test::MockModule->new('IO::Prompter');
    $mock->redefine( prompt => sub { $asked++; return 'typed at a terminal' } );

    load_block("keepass: handed in\n");

    is( Trog::Credentials->prompt( 'passphrase:', 'keepass' ), 'handed in', 'a named password that was handed in is not asked for' );
    is( $asked,                                                0,           'nobody was prompted' );

    is( Trog::Credentials->prompt( 'sudo:', 'sudo' ), 'typed at a terminal', 'one that was not is asked for' );
    is( $asked,                                       1,                     'exactly once' );

    # Something with no name is always asked for, which is the old behavior and
    # what anything without a name in the block should get.
    is( Trog::Credentials->prompt('something else:'), 'typed at a terminal', 'and an unnamed password is always asked for' );
    is( $asked,                                       2,                     'again' );

    # A name nobody can hand in is refused before the question, not after
    # somebody has typed the answer.
    like( exception { Trog::Credentials->prompt( 'passphrase:', 'keypass' ) }, qr/Unknown[ ]credential[ ]'keypass'/, 'a name that is not one is refused' );
    is( $asked, 2, 'without asking first' );
};

subtest 'asking at the terminal, for a caller whose standard input is spoken for' => sub {
    Trog::Credentials->forget();

    # A file standing in for /dev/tty, holding what would have been typed.
    my $terminal = sub {
        my ($typed) = @_;
        my $fh = File::Temp->new();
        print {$fh} $typed;
        close($fh) or die 'Could not close ' . $fh->filename . ": $!";
        return $fh;
    };

    my $tty = $terminal->("typed there\n");
    local $Trog::Credentials::TERMINAL = $tty->filename;
    is( Trog::Credentials->prompt( 'passphrase:', 'keepass', terminal => 1 ), 'typed there', 'what was typed at the terminal is the answer' );
    is( Trog::Credentials->get('keepass'),                                    'typed there', 'and it is kept for the rest of the run' );

    $tty = $terminal->("\n");
    local $Trog::Credentials::TERMINAL = $tty->filename;
    is( Trog::Credentials->prompt( 'sudo:', undef, terminal => 1 ), q{}, 'an empty line is an empty password, not a missing one' );

    # What bin/add_secret --stdin hit: the input was gone before anything was
    # typed.  That is no answer, and saying so beats a warning about undef.
    $tty = $terminal->(q{});
    local $Trog::Credentials::TERMINAL = $tty->filename;
    like( exception { Trog::Credentials->prompt( 'sudo:', 'sudo', terminal => 1 ) }, qr/Nothing[ ]was[ ]typed[ ]for[ ]sudo:[ ]its[ ]input[ ]ended/, 'input that ends with no answer is refused' );
    is( Trog::Credentials->have('sudo'), 0, 'and nothing is remembered for it' );

    local $Trog::Credentials::TERMINAL = '/bogus/tty';
    my $why = exception { Trog::Credentials->prompt( 'sudo:', 'sudo', terminal => 1 ) };
    like( $why, qr{Cannot[ ]ask[ ]for[ ]sudo[ ]at[ ]a[ ]terminal:[ ]/bogus/tty}, 'no terminal to open is refused' );
    like( $why, qr/already[ ]spoken[ ]for/,                                      'saying why it had to be the terminal' );
};

subtest 'sudo on a machine nobody is watching' => sub {
    require Trog::HV;

    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( describe   => sub { 'hv.example.test' } );
    $machine->redefine( ssh_user   => sub { 'ubuntu' } );
    $machine->redefine( ssh_target => sub { 'ubuntu@hv.example.test' } );
    local $Trog::Credentials::TERMINAL = '/bogus/tty';

    Trog::HV->forget();
    my $hv = Trog::HV->new( uri => 'qemu+ssh://ubuntu@hv.example.test/system' );
    Trog::Machine::forget_sudo_passwords();

    # This is the case the whole thing is for: a detached run, sudo on the far
    # side wanting a password, and no terminal in sight.
    load_block("sudo: hunter2\n");
    Trog::Machine::_ask_for_sudo_password($hv);    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
    is( $hv->sudo_password, 'hunter2', 'the password handed in is the one sudo gets' );

    # And without it, the same run says what to do rather than hanging.
    Trog::Credentials->forget();
    Trog::Credentials->load( IO::String->new('') );
    Trog::Machine::forget_sudo_passwords();

    my $why = exception { Trog::Machine::_ask_for_sudo_password($hv) };    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
    like( $why, qr/Cannot[ ]ask[ ]for[ ]sudo[ ]at[ ]a[ ]terminal/, 'with nothing handed in and no terminal it refuses' );
    like( $why, qr/NOPASSWD/,                                      'saying how to not need one' );
    like( $why, qr/Trog::Credentials/,                             'and how to hand one in' );
};

subtest 'remember keeps what was typed for the rest of the run' => sub {
    Trog::Credentials->forget();

    ok( !Trog::Credentials->have('keepass'), 'nothing to start with' );

    Trog::Credentials->remember( 'keepass', 'typed at a prompt' );
    ok( Trog::Credentials->have('keepass'), 'and now there is' );
    is( Trog::Credentials->get('keepass'), 'typed at a prompt', 'which is what was typed' );

    # The allowlist is the whole point of the module: a name nobody can ask for
    # is a name that would sit here being never used.
    like( exception { Trog::Credentials->remember( 'keypass', 'a typo' ) }, qr/Unknown[ ]credential/, 'a name that is not one is refused' );

    Trog::Credentials->forget();
    ok( !Trog::Credentials->have('keepass'), 'and forget clears it like any other' );
};

# bin/provision hands this to each run it starts for an upstream guest.
subtest 'block gives back what load reads' => sub {
    Trog::Credentials->forget();
    is( Trog::Credentials->block(), q{}, 'nothing held, nothing to give' );

    open( my $in, '<', \"sudo: the sudo one\nkeepass: the store one\n\n" ) or die;
    Trog::Credentials->load($in);
    close($in) or die;
    my $block = Trog::Credentials->block();
    is( $block, "keepass: the store one\nsudo: the sudo one\n\n", 'a line for each, and the blank line that ends it' );

    Trog::Credentials->forget();
    open( my $again, '<', \$block ) or die;
    Trog::Credentials->load($again);
    close($again) or die;
    is( Trog::Credentials->get('sudo'), 'the sudo one', 'and load reads it back' );
    Trog::Credentials->forget();
};

done_testing();
