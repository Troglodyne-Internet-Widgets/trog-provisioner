#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/new_config-transfer.t - what bin/new_config writes that depends on the
hypervisor it chose: where the guest fetches its payload from, and the pin
that makes bin/provision build it there

=cut

use FindBin;
use FindBin::libs;

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

# What transfer_to asks of the hypervisor and of this machine, and nothing else.
{

    package Test::Hypervisor;
    sub new                      ( $class, %o ) { return bless {%o}, $class }
    sub configured_transfer_ip   ($self)        { return $self->{ip} }
    sub configured_transfer_port ($self)        { return $self->{port} }
    sub describe ($) { return 'the test cloud' }
    sub name     ($self) { return $self->{name} }
    sub size_key ($self) { return $self->{size_key} }

    package Test::ThisMachine;
    sub new ( $class, %o ) { return bless {%o}, $class }
    sub sshd_port ($)      { return 22 }
    sub transfer_user ($)  { return 'provisioner' }
    sub describe ($)       { return 'this machine' }

    sub transfer_ips ( $self, @towards ) {
        push @{ $self->{asked} }, @towards;
        return @{ $self->{routes} // [] };
    }
}

my %GLOBAL = ( transfer_ip => '198.51.100.1', transfer_port => 2200, transfer_user => 'fetcher' );

subtest 'transfer_to' => sub {
    my $here = Test::ThisMachine->new( routes => [ '10.0.0.2', '10.0.1.2' ] );

    is_deeply(
        [ Trog::Provisioner::Config::Generator::transfer_to( Test::Hypervisor->new( ip => '192.0.2.10', port => 2222 ), $here, {%GLOBAL}, 'vm.test.test' ) ],
        [ ['192.0.2.10'], 2222, 'fetcher' ],
        'the block of the hypervisor wins over _global, address and port',
    );

    is_deeply(
        [ Trog::Provisioner::Config::Generator::transfer_to( Test::Hypervisor->new, $here, {%GLOBAL}, 'vm.test.test', '10.0.0.5' ) ],
        [ ['198.51.100.1'], 2200, 'fetcher' ],
        'a block that says nothing leaves it to _global, which wins over the routing table',
    );
    is_deeply( $here->{asked}, undef, 'which is not asked' );

    is_deeply(
        [ Trog::Provisioner::Config::Generator::transfer_to( Test::Hypervisor->new, $here, {}, 'vm.test.test', '10.0.0.5' ) ],
        [ [ '10.0.0.2', '10.0.1.2' ], 22, 'provisioner' ],
        'with neither, every address the routing table says reaches the guest, at the port and account of this machine',
    );
    is_deeply( $here->{asked}, ['10.0.0.5'], 'asked about the guest\'s address' );

    is_deeply(
        [ Trog::Provisioner::Config::Generator::transfer_to( Test::Hypervisor->new( port => 2222 ), $here, {}, 'vm.test.test', '10.0.0.5' ) ],
        [ [ '10.0.0.2', '10.0.1.2' ], 2222, 'provisioner' ],
        'a block can name only the port',
    );

    my $err = exception { Trog::Provisioner::Config::Generator::transfer_to( Test::Hypervisor->new, $here, {}, 'vm.test.test' ) };
    like( $err, qr/no[ ]address[ ]of[ ]vm[.]test[.]test/, 'a cloud with nothing named is refused' );
    like( $err, qr/block[ ]of[ ]the[ ]hypervisor/,        'saying where to name it' );

    like(
        exception { Trog::Provisioner::Config::Generator::transfer_to( Test::Hypervisor->new, Test::ThisMachine->new, {}, 'vm.test.test', '10.0.0.5' ) },
        qr/can[ ]be[ ]reached[ ]from[ ]vm[.]test[.]test/,
        'and a guest none of our addresses reaches is said',
    );
};

subtest 'placement_lines' => sub {
    my $placed = Test::Hypervisor->new( name => 'linode1', size_key => 'linode_type' );

    is(
        Trog::Provisioner::Config::Generator::placement_lines( $placed, { linode_type => 'g6-standard-2' } ),
        "\nhypervisor=linode1\nlinode_type=g6-standard-2\n",
        'a guest placed on a hypervisor of the fleet is pinned to it, and told what it is there, so bin/provision builds the same guest in the same place'
    );

    is(
        Trog::Provisioner::Config::Generator::placement_lines( $placed, {} ),
        "\nhypervisor=linode1\n",
        'a guest that names no size for that kind of hypervisor writes none'
    );

    is(
        Trog::Provisioner::Config::Generator::placement_lines( Test::Hypervisor->new, { linode_type => 'g6-standard-2' } ),
        q{},
        'and one with no fleet is left to whatever bin/provision is given'
    );
};

Test::NoWarnings::had_no_warnings();
done_testing();
