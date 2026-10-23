#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-edge.t - the commands that another guest runs on an edge,
to register its names and to release them

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp();
use File::Slurper::Temp();

use FindBin::libs;

use Provisioner::Cookbook();
use Provisioner::Utils();

my $edge = Provisioner::Cookbook->load('edge');

subtest 'a guest registers its names on the edge, which issues it a key' => sub {
    my %files = $edge->issue_grant( { recipe => 'edge', guest => 'edge.test.test', client => 'web.test.test' }, upstreams => { tls => '192.0.2.10:8443', http => '192.0.2.10:8080' }, names => [qw{public.web.test.test www.customer.test}] );
    is_deeply(
        \%files,
        {
            '/etc/fail2ban/edge/web.test.test.key.b64' => {
                issue => { guest => 'edge.test.test', command => '/root/bin/edge_client register web.test.test 192.0.2.10:8443 192.0.2.10:8080 public.web.test.test www.customer.test' },
                owner => 'root:root',
                mode  => '0600',
            },
            '/etc/fail2ban/edge/web.test.test.host.b64' => {
                issue => { guest => 'edge.test.test', command => 'base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub' },
                owner => 'root:root',
                mode  => '0644',
            },
        },
        'edge_client registers each name for TLS, then for plain HTTP, and the key lands at the key path of the domain, beside the host key of the edge'
    );
    is( $edge->key_path('web.test.test'), '/etc/fail2ban/edge/web.test.test.key.b64', 'which is the one file of the domain' );
};

subtest 'bin/destroy releases them by the same script' => sub {
    my %revocation = $edge->revoke_grant( { recipe => 'edge', guest => 'edge.test.test', client => 'web.test.test' } );
    is( $revocation{command}, '/root/bin/edge_client release web.test.test', 'edge_client release, for the domain' );
    like( $revocation{stays}, qr/Run[ ]\Q$revocation{command}\E[ ]there/, 'and an edge that is not up is told the same command' );
};

subtest 'the guests reach the edge through its tunnel when it has one' => sub {
    my %held;
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( holdings => sub { return {%held} } );

    %held = ( guests => '192.0.2.5' );
    is( $edge->address('edge.test.test'), '192.0.2.5', 'an edge on the LAN, at its address there' );

    %held = ( guests => '192.0.2.5', vpnclients => '198.51.100.5' );
    is( $edge->address('edge.test.test'), '198.51.100.5', 'an edge that is a client of the VPN, at its address there' );

    %held = ( vpnclients => '198.51.100.5', others => '203.0.113.5' );
    like( exception { $edge->address('edge.test.test') }, qr/an[ ]address[ ]in[ ]each[ ]of[ ]others,[ ]vpnclients/, 'two tunnels are a question it does not guess at' );

    %held = ();
    like( exception { $edge->address('edge.test.test') }, qr/edge[.]test[.]test[ ]has[ ]no[ ]address/, 'and an edge with no address stops the build' );
};

subtest 'the host key comes from the store' => sub {
    my %secrets = $edge->guest_secrets( '/opt/domains', 'edge.test.test' );
    my $secret  = $secrets{'/etc/ssh/ssh_host_ed25519_key'};
    is( $secret->{ref},  'secret:edge/edge.test.test-ssh-host-key/password', 'so a rebuilt edge keeps the host key that the guests pinned' );
    is( $secret->{mode}, '0600',                                             'readable by root only' );

    my $file = File::Temp::tempdir( CLEANUP => 1 ) . '/key';
    File::Slurper::Temp::write_binary( $file, $secret->{generate}->() . "\n" );
    like( Provisioner::Utils::ssh_pubkey_from_private($file), qr/\Assh-ed25519[ ]/, 'and the key that it generates is an ed25519 key with no passphrase' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
