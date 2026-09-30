#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Trog-Hypervisors-Config.t - Trog::Hypervisors::Config: reading the fleet's
file, and the secrets its blocks name

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper::Temp();

use FindBin::libs;

use_ok('Trog::Hypervisors::Config');

sub fleet_of {
    my ($text) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/hypervisors.conf", $text );
    return "$dir/hypervisors.conf";
}

subtest 'load' => sub {
    my $fleet = Trog::Hypervisors::Config->load('/bogus/hypervisors.conf');
    ok( !$fleet->configured, 'no hypervisors.conf means no fleet' );
    is_deeply( [ $fleet->names ], [], 'and it names nobody' );
    ok( !Trog::Hypervisors::Config->load(undef)->configured, 'an undef path is the same thing' );

    $fleet = Trog::Hypervisors::Config->load( fleet_of("[b]\nlibvirt_uri = qemu:///system\n\n[a]\nlibvirt_uri = qemu:///system\n") );
    is_deeply( [ $fleet->names ], [qw{b a}], 'a fleet is read in the order of the file, not sorted' );

    like(
        exception { Trog::Hypervisors::Config->load( fleet_of("libvirt_uri=qemu:///system\n") ) }, qr/names[ ]no[ ]hypervisors/,
        'a file with no blocks is an error, rather than silently finding nothing'
    );

    ok( !$INC{'Trog/HV.pm'}, 'and reading it builds no hypervisor, so a module the backends load can read it too' );
};

subtest 'secret_references' => sub {
    my $fleet = Trog::Hypervisors::Config->load( fleet_of(<<'CONF') );
[node1]
solusvm       = node1.test.test
solusvm_token = secret:solusvm/api/password

[node2]
solusvm       = node2.test.test
solusvm_token = secret:solusvm/api/password

[lin]
linode_token  = secret:linode/api/password

[local]
libvirt_uri   = qemu:///system
CONF

    is_deeply( [ $fleet->secret_references ], [qw{secret:linode/api/password secret:solusvm/api/password}], 'every reference a block names, once each and sorted' );

    is_deeply( [ Trog::Hypervisors::Config->load( fleet_of("[local]\nlibvirt_uri = qemu:///system\n") )->secret_references ], [], 'a fleet that names no secret wants none' );
    is_deeply( [ Trog::Hypervisors::Config->load(undef)->secret_references ],                                                 [], 'and nor does no fleet at all' );
};

done_testing();
