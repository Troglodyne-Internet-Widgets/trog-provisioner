#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/new_config-network.t - required_network in bin/new_config: the network that
a guest must be on to reach the guests it needs

=cut

use FindBin;
use FindBin::libs;
use Test::More;
use Test::Fatal;
use Test::MockModule qw{strict};
use Test::NoWarnings qw{had_no_warnings};
use Capture::Tiny    qw{capture_stdout};

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

# A fleet that is only the answer to where each guest is.
my %where;
my $configured = 1;
{

    package NetworkProbe::HV;
    sub new     { my ( $class, %o ) = @_; return bless {%o}, $class }
    sub name    { my ($self) = @_; return $self->{name} }
    sub network { my ($self) = @_; return $self->{network} }

    package NetworkProbe::Fleet;
    sub configured { return $configured }
    sub hosting    { my ( undef, $domain ) = @_; return $where{$domain} }
}
my $load = Test::MockModule->new('Trog::Hypervisors');
$load->redefine( load => sub { return bless {}, 'NetworkProbe::Fleet' } );

my %conf = (
    _base        => { _global      => { cache => 'cache.test' }, logshipper => { host => 'logs.test' } },
    'cache.test' => { fetchcache   => {} },
    'logs.test'  => { logcollector => {} },
    'web.test'   => { cron         => {} },
    'plain.test' => { _global      => { cache => q{} }, logshipper => { host => 'syslog.vendor.test' } },
);
my $home  = NetworkProbe::HV->new( name => 'hv1',    network => 'home' );
my $home2 = NetworkProbe::HV->new( name => 'hv2',    network => 'home' );
my $cloud = NetworkProbe::HV->new( name => 'linode', network => 'cloud' );

sub required {
    my ($domain) = @_;
    my @got;
    my $said = capture_stdout { @got = Trog::Provisioner::Config::Generator::required_network( $domain, \%conf, '/bogus/hypervisors.conf' ) };
    return ( {@got}, $said );
}

%where = ( 'cache.test' => $home, 'logs.test' => $home2 );
my ($need) = required('web.test');
is( $need->{network}, 'home', 'the network of the guests it needs, on two hypervisors of one network' );
like( $need->{network_why}, qr/it[ ]needs[ ]cache[.]test,[ ]which[ ]is[ ]on[ ]hv1/, 'saying which guests, on which hypervisors' );
like( $need->{network_why}, qr/logs[.]test,[ ]which[ ]is[ ]on[ ]hv2/,               'each of them' );

is_deeply( ( required('plain.test') )[0], {}, 'a guest that needs nothing may go anywhere' );

%where = ( 'cache.test' => $home );
my ( $partial, $said ) = required('web.test');
is( $partial->{network}, 'home', 'a guest that is not up yet does not limit it' );
like( $said, qr/logs[.]test[ ]is[ ]not[ ]up/, 'and says so' );

%where = ( 'cache.test' => $home, 'logs.test' => $cloud );
my $err = exception { required('web.test') };
$err //= q{};
like( $err, qr/needs[ ]guests[ ]that[ ]are[ ]on[ ]different[ ]networks/,      'guests on two networks are refused' );
like( $err, qr/network[ ]'cloud':[ ]logs[.]test,[ ]which[ ]is[ ]on[ ]linode/, 'naming each' );

$configured = 0;
is_deeply( ( required('web.test') )[0], {}, 'and with no fleet there is one hypervisor, and nothing to choose' );

had_no_warnings();
done_testing();
