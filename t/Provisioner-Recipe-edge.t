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

use FindBin::libs;

use Provisioner::Cookbook();

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
        },
        'edge_client registers each name for TLS, then for plain HTTP, and the key lands at the key path of the domain'
    );
    is( $edge->key_path('web.test.test'), '/etc/fail2ban/edge/web.test.test.key.b64', 'which is the one file of the domain' );
};

subtest 'bin/destroy releases them by the same script' => sub {
    my %revocation = $edge->revoke_grant( { recipe => 'edge', guest => 'edge.test.test', client => 'web.test.test' } );
    is( $revocation{command}, '/root/bin/edge_client release web.test.test', 'edge_client release, for the domain' );
    like( $revocation{stays}, qr/Run[ ]\Q$revocation{command}\E[ ]there/, 'and an edge that is not up is told the same command' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
