#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/new_config-resolvers.t - the resolvers of a guest, from its hypervisor or from _global

=cut

use Test::More;
use Test::Fatal qw{exception};

use FindBin;
use FindBin::libs;

# Never the configuration of the installation.
## no critic (CompileTime) -- setting it at compile time is the point
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns

use Trog::HV();

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

# A hypervisor that answers only what its block names.
{

    package ResolverProbe::HV;
    sub new                  { my ( $class, @r ) = @_; return bless [@r], $class }
    sub configured_resolvers { my ($self) = @_; return @$self }
    sub name                 { return 'hv1' }
}

subtest 'guest_resolvers: the hypervisor names the resolvers of its guests' => sub {
    is_deeply( [ Trog::Provisioner::Config::Generator::guest_resolvers( ResolverProbe::HV->new(qw{1.1.1.1 9.9.9.9}) ) ], [qw{1.1.1.1 9.9.9.9}], 'a guest gets those that the block of its hypervisor names' );

    my $none = exception { Trog::Provisioner::Config::Generator::guest_resolvers( ResolverProbe::HV->new() ) };
    like( $none, qr/hv1[ ]in[ ]hypervisors[.]conf[ ]names[ ]no[ ]resolvers/, 'and a block that names none is refused, by the name of the hypervisor' );
    like( $none, qr/resolvers[ ]=[ ]1[.]1[.]1[.]1/,                          'with the line that would fix it' );

    like( exception { Trog::Provisioner::Config::Generator::guest_resolvers( ResolverProbe::HV->new('127.0.0.1') ) }, qr/127[.]0[.]0[.]1.*hypervisors[.]conf/s, 'a loopback resolver is refused, and the refusal names the file' );
};

subtest 'configured_resolvers: the resolvers of a block of hypervisors.conf' => sub {
    my $hv = sub { my (%block) = @_; return Trog::HV->new( Trog::HV->options_from_block( { libvirt_uri => 'qemu:///system', %block } ) ) };

    is_deeply( [ $hv->( resolvers => '1.1.1.1, 8.8.8.8' )->configured_resolvers ],    [qw{1.1.1.1 8.8.8.8}], 'a list separated by commas' );
    is_deeply( [ $hv->( resolvers => [qw{1.1.1.1 8.8.8.8}] )->configured_resolvers ], [qw{1.1.1.1 8.8.8.8}], 'and the list that Config::Simple makes of one' );
    is_deeply( [ $hv->()->configured_resolvers ], [], 'and none when the block names none' );
    like( exception { $hv->( resolvers => '1.1.1.1, dns.test.test' )->configured_resolvers }, qr/'dns[.]test[.]test',[ ]which[ ]is[ ]not[ ]an[ ]address/, 'a name in place of an address is refused' );
};

done_testing();
