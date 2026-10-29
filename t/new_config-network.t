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

# A VPN client reaches the network of its server from anywhere.
$conf{'vpn.test'}  = { openvpn       => {} };
$conf{'edge.test'} = { openvpnclient => { server => 'vpn.test', issue_from => 'vpn.test' } };
%where             = ( 'cache.test' => $home, 'logs.test' => $home2, 'vpn.test' => $home );
my ( $edge, $edge_said ) = required('edge.test');
is_deeply( $edge, {}, 'a VPN client may go anywhere, when what it needs is on the network of its server' );
like( $edge_said, qr/cache[.]test[ ]does[ ]not[ ]limit/,               'and says which guest no longer limits it' );
like( $edge_said, qr/openvpnclient[ ]connects[ ]it[ ]to[ ]vpn[.]test/, 'and why' );

%where = ( 'cache.test' => $home, 'logs.test' => $cloud, 'vpn.test' => $home );
is( ( required('edge.test') )[0]{network}, 'cloud', 'but a guest that it needs on another network still limits it' );

%where = ( 'cache.test' => $home, 'logs.test' => $home2 );
is( ( required('edge.test') )[0]{network}, 'home', 'and a server that is not up brings it onto no network' );

# A guest reaches a VPN client on another network through the network of its
# server.
$conf{'relayed.test'} = { logshipper => { host  => 'edge.test' } };
$conf{'alone.test'}   = { _global    => { cache => q{} }, logshipper => { host => 'edge.test' } };
%where                = ( 'cache.test' => $home, 'edge.test' => $cloud, 'vpn.test' => $home2 );
my ($relayed) = required('relayed.test');
is( $relayed->{network}, 'home', 'a VPN client on another network is reached on the network of its server' );
my $joins = qr/openvpnclient[ ]connects[ ]it[ ]to[ ]vpn[.]test/;
like( $relayed->{network_why}, qr/edge[.]test,[ ]where[ ]${joins}[ ]on[ ]hv2/, 'which it says' );
is( ( required('alone.test') )[0]{network}, 'cloud', 'and with nothing else to reach, it goes where the client is' );

%where = ( 'cache.test' => NetworkProbe::HV->new( name => 'hv3', network => 'office' ), 'edge.test' => $cloud, 'vpn.test' => $home );
like( ( exception { required('relayed.test') } ) // q{}, qr/network[ ]'office':[ ]cache[.]test/, 'but a network that the client does not reach is still refused' );

sub peers {
    my ( $domain, $hv ) = @_;
    return [ Trog::Provisioner::Config::Generator::network_peers( $domain, \%conf, '/bogus/hypervisors.conf', $hv ) ];
}

%where = ( 'vpn.test' => $home2 );
is_deeply( peers( 'edge.test', $home ),  ['vpn.test'], 'a VPN client on the network of its server, on another hypervisor there, is its peer' );
is_deeply( peers( 'edge.test', $cloud ), [],           'and a client on another network is not' );
is_deeply( peers( 'web.test',  $home ),  [],           'a guest that joins no network has no peers' );

%where = ();
is_deeply( peers( 'edge.test', $home ), [], 'and a server that is not up is not a peer' );

$configured = 0;
is_deeply( ( required('web.test') )[0], {}, 'and with no fleet there is one hypervisor, and nothing to choose' );

is_deeply( peers( 'edge.test', $home ), ['vpn.test'], 'with no fleet, a server that this installation configures is a peer' );
$conf{'away.test'} = { openvpnclient => { server => 'vpn.vendor.test', cert_dir => '/bogus' } };
is_deeply( peers( 'away.test', $home ), [], 'and a server of somebody else is not' );

had_no_warnings();
done_testing();
