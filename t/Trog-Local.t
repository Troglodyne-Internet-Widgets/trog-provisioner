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

subtest 'it is us, and says so' => sub {
    my $us = Trog::Local->new();

    ok( $us->is_local, 'this machine is local, which is the whole point of the class' );
    is( $us->describe, 'this machine', 'and is called that in an error' );

    # Inherited from Trog::Machine, whose local branches answer without opening
    # a connection.  They are here rather than on Trog::HV because they describe
    # whoever holds a guest's payload, and that is us.
    is( $us->transfer_user,   scalar getpwuid($<),               'the transfer user is whoever is running this' );
    is( $us->authorized_keys, "$ENV{HOME}/.ssh/authorized_keys", 'and it is their own authorized_keys' );
};

subtest 'which of our addresses a guest would reach us at' => sub {
    my $us = Trog::Local->new();

    # Loopback rather than anything real: every machine this could run on
    # answers the same, and the answer is not a guess about the network the
    # test happens to be on.
    is( $us->transfer_ip('127.0.0.1'), '127.0.0.1', 'the source address the routing table would use' );

    # A guest reaches us across the hypervisor's networks, so the address to
    # aim at is not ours to invent.
    like(
        exception { $us->transfer_ip() },
        qr/has to be given/,
        'asking without saying which network is an error rather than a guess'
    );

    is( $us->transfer_ip('not an address'), undef, 'and something that is not an address is no answer' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
