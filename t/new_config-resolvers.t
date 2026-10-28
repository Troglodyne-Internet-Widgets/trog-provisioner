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
    sub new { my ( $class, @r ) = @_; return bless [@r], $class }
    sub configured_resolvers { my ($self) = @_; return @$self }
}

subtest 'guest_resolvers: the hypervisor answers first' => sub {
    my @global = qw{192.168.1.254 8.8.8.8};
    is_deeply( [ Trog::Provisioner::Config::Generator::guest_resolvers( ResolverProbe::HV->new(qw{1.1.1.1 9.9.9.9}), @global ) ], [qw{1.1.1.1 9.9.9.9}], 'a block that names resolvers gives its guests those, and not the gateway of the installation' );
    is_deeply( [ Trog::Provisioner::Config::Generator::guest_resolvers( ResolverProbe::HV->new(),                    @global ) ], \@global,              'and a block that names none gives them those of _global' );

    like( exception { Trog::Provisioner::Config::Generator::guest_resolvers( ResolverProbe::HV->new('127.0.0.1'), @global ) }, qr/127[.]0[.]0[.]1.*hypervisors[.]conf/s, 'a loopback resolver in a block is refused, and the refusal names the file' );
    like( exception { Trog::Provisioner::Config::Generator::guest_resolvers( ResolverProbe::HV->new(),            '::1' ) },   qr/::1/,                                  'and so is one in _global' );
};

subtest 'configured_resolvers: the resolvers of a block of hypervisors.conf' => sub {
    my $hv = sub { my (%block) = @_; return Trog::HV->new( Trog::HV->options_from_block( { libvirt_uri => 'qemu:///system', %block } ) ) };

    is_deeply( [ $hv->( resolvers => '1.1.1.1, 8.8.8.8' )->configured_resolvers ],    [qw{1.1.1.1 8.8.8.8}], 'a list separated by commas' );
    is_deeply( [ $hv->( resolvers => [qw{1.1.1.1 8.8.8.8}] )->configured_resolvers ], [qw{1.1.1.1 8.8.8.8}], 'and the list that Config::Simple makes of one' );
    is_deeply( [ $hv->()->configured_resolvers ], [], 'and none when the block names none' );
    like( exception { $hv->( resolvers => '1.1.1.1, dns.test.test' )->configured_resolvers }, qr/'dns[.]test[.]test',[ ]which[ ]is[ ]not[ ]an[ ]address/, 'a name in place of an address is refused' );
};

done_testing();
