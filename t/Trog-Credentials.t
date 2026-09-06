#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Trog::Credentials();
use Trog::Secrets();

sub given {
    my ($block) = @_;
    Trog::Credentials->forget();
    Trog::Credentials->load( IO::String->new($block) );
    return;
}

subtest 'what a block says' => sub {
    given ("keepass: correct horse battery staple\nsudo: hunter2\n");

    is( Trog::Credentials->get('keepass'), 'correct horse battery staple', 'the passphrase' );
    is( Trog::Credentials->get('sudo'),    'hunter2',                      'and the sudo password' );
    is( Trog::Credentials->have('sudo'),   1,                              'both are there' );

    # Not given is not the same as given empty, and the difference is whether
    # anybody gets prompted.
    given ("keepass: only this one\n");
    is( Trog::Credentials->have('sudo'), 0,     'a name not given is not there' );
    is( Trog::Credentials->get('sudo'),  undef, 'and reads as nothing' );

    given ("sudo:\n");
    is( Trog::Credentials->have('sudo'), 1,  'a name given empty is there' );
    is( Trog::Credentials->get('sudo'),  '', 'and is empty rather than missing' );
};

subtest 'what a password is allowed to be' => sub {

    # Exactly one space after the colon is the separator; everything after it is
    # the password, whatever it looks like.
    given ("sudo:  two spaces, so one leading\n");
    is( Trog::Credentials->get('sudo'), ' two spaces, so one leading', 'leading whitespace survives' );

    given ("sudo: trailing space \n");
    is( Trog::Credentials->get('sudo'), 'trailing space ', 'and trailing' );

    given ("sudo: has: a colon: in it\n");
    is( Trog::Credentials->get('sudo'), 'has: a colon: in it', 'a colon in the password is just a colon' );

    given ("keepass: correct horse\n\nsudo: never read\n");
    is( Trog::Credentials->have('sudo'), 0, 'a blank line ends the block' );
};

subtest 'a name it does not know is an error, not a shrug' => sub {

    # The failure this prevents: a misspelling that quietly means "prompt for
    # it", on a run with no terminal, which hangs or dies minutes later.
    like(
        exception { given ("keypass: mistyped\n") },
        qr/Unknown credential 'keypass'/,
        'a misspelled name is refused'
    );
    like( exception { given ("keypass: mistyped\n") }, qr/keepass, sudo/, 'and it says what the names are' );

    like(
        exception { given ("just a bare password\n") },
        qr/Expected 'name: value'/,
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

    given ("keepass: handed in\n");

    is( Trog::Secrets->prompt( 'passphrase:', 'keepass' ), 'handed in', 'a named password that was handed in is not asked for' );
    is( $asked,                                            0,           'nobody was prompted' );

    is( Trog::Secrets->prompt( 'sudo:', 'sudo' ), 'typed at a terminal', 'one that was not is asked for' );
    is( $asked,                                   1,                     'exactly once' );

    # Something with no name is always asked for, which is the old behaviour and
    # what anything without a name in the block should get.
    is( Trog::Secrets->prompt('something else:'), 'typed at a terminal', 'and an unnamed password is always asked for' );
    is( $asked,                                   2,                     'again' );
};

subtest 'sudo on a machine nobody is watching' => sub {
    require Trog::HV;

    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( describe       => sub { 'hv.example.com' } );
    $machine->redefine( ssh_user       => sub { 'ubuntu' } );
    $machine->redefine( ssh_target     => sub { 'ubuntu@hv.example.com' } );
    $machine->redefine( _have_terminal => sub { 0 } );

    Trog::HV->forget();
    my $hv = Trog::HV->new( uri => 'qemu+ssh://ubuntu@hv.example.com/system' );
    Trog::Machine::forget_sudo_passwords();

    # This is the case the whole thing is for: a detached run, sudo on the far
    # side wanting a password, and no terminal in sight.
    given ("sudo: hunter2\n");
    Trog::Machine::_ask_for_sudo_password($hv);
    is( $hv->sudo_password, 'hunter2', 'the password handed in is the one sudo gets' );

    # And without it, the same run says what to do rather than hanging.
    Trog::Credentials->forget();
    Trog::Credentials->load( IO::String->new('') );
    Trog::Machine::forget_sudo_passwords();

    my $why = exception { Trog::Machine::_ask_for_sudo_password($hv) };
    like( $why, qr/no terminal to ask at/, 'with nothing handed in it refuses' );
    like( $why, qr/NOPASSWD/,              'saying how to not need one' );
    like( $why, qr/Trog::Credentials/,     'and how to hand one in' );
};

done_testing();
