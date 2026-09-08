#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Trog-Local.t - Trog::Local: this machine, and which of its addresses a guest can reach

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};

use FindBin::libs;

use_ok('Trog::Local') or BAIL_OUT('Trog::Local does not load; the install is incomplete');

subtest 'it is this machine, and says so' => sub {
    my $this_machine = Trog::Local->new();

    ok( $this_machine->is_local, 'this machine is local, which is the whole point of the class' );
    is( $this_machine->describe, 'this machine', 'and is called that in an error' );

    # Inherited from Trog::Machine, whose local branches answer without opening
    # a connection.  They are there rather than on Trog::HV because they
    # describe whoever holds a guest's payload, and that is this machine.
    is( $this_machine->transfer_user,   scalar getpwuid($<),               'the transfer user is whoever is running this' );
    is( $this_machine->authorized_keys, "$ENV{HOME}/.ssh/authorized_keys", 'and it is their own authorized_keys' );
};

subtest 'there is only one machine we are running on' => sub {
    Trog::Local->forget();

    my $first = Trog::Local->new();
    is( Trog::Local->new(), $first, 'asking twice gets the same one' );

    Trog::Local->forget();
    isnt( Trog::Local->new(), $first, 'and forgetting is how a test gets a fresh one' );
};

subtest 'which of our addresses a guest would reach us at' => sub {
    my $this_machine = Trog::Local->new();

    # Loopback rather than anything real: every machine this could run on
    # answers the same, and the answer is not a guess about the network the
    # test happens to be on.
    is( $this_machine->transfer_ip('127.0.0.1'), '127.0.0.1', 'the source address the routing table would use' );

    # A guest has more than one address on more than one network, and which of
    # them we share with it is not knowable from here.  So they are tried in
    # order, and one that goes nowhere is skipped rather than being the answer.
    is( $this_machine->transfer_ip( 'not an address', '127.0.0.1' ), '127.0.0.1', 'the first that routes decides' );

    # A domain's configured address is written as a cidr, and a network is not
    # something to connect to.
    is( $this_machine->transfer_ip('127.0.0.1/8'), '127.0.0.1', 'a cidr is taken as the address in it' );

    like(
        exception { $this_machine->transfer_ip() },
        qr/has to be given/,
        'asking without saying which addresses is an error rather than a guess'
    );

    is( $this_machine->transfer_ip('not an address'), undef, 'and nothing that routes is no answer' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
