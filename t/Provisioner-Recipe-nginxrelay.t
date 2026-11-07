#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-nginxrelay.t - the commands that another guest runs on a
web relay, to register its names and to release them

=cut

use Test::More;
use Test::NoWarnings;

use FindBin::libs;

use Provisioner::Cookbook();

my $relay = Provisioner::Cookbook->load('nginxrelay');

subtest 'a guest registers its names on the relay, which issues it a key' => sub {
    my %files = $relay->issue_grant( { recipe => 'nginxrelay', guest => 'relay.test.test', client => 'web.test.test' }, upstreams => { tls => '192.0.2.10:8443', http => '192.0.2.10:8080' }, names => [qw{public.web.test.test www.customer.test}] );
    is_deeply(
        \%files,
        {
            '/etc/fail2ban/nginxrelay/web.test.test.key.b64' => {
                issue => { guest => 'relay.test.test', command => '/root/bin/nginxrelay_client register web.test.test 192.0.2.10:8443 192.0.2.10:8080 public.web.test.test www.customer.test' },
                owner => 'root:root',
                mode  => '0600',
            },
            '/etc/fail2ban/nginxrelay/web.test.test.host.b64' => {
                issue => { guest => 'relay.test.test', command => 'base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub' },
                owner => 'root:root',
                mode  => '0644',
            },
        },
        'nginxrelay_client registers each name for TLS, then for plain HTTP, and the key lands at the key path of the domain, beside the host key of the relay'
    );
    is( $relay->key_path('web.test.test'), '/etc/fail2ban/nginxrelay/web.test.test.key.b64', 'which is the one file of the domain' );
};

subtest 'a guest with media names registers them too, and gets a key to send their certificates' => sub {
    my $grant = { recipe => 'nginxrelay', guest => 'relay.test.test', client => 'web.test.test' };
    my %files = $relay->issue_grant( $grant, upstreams => { tls => '192.0.2.10:8443', http => '192.0.2.10:8080' }, names => ['public.web.test.test'], media => ['media.web.test.test'] );

    is( $files{ $relay->key_path('web.test.test') }{issue}{command}, '/root/bin/nginxrelay_client register web.test.test 192.0.2.10:8443 192.0.2.10:8080 public.web.test.test --media media.web.test.test', 'each media name goes to register after --media' );
    is_deeply(
        $files{ $relay->media_key_path('web.test.test') },
        { issue => { guest => 'relay.test.test', command => '/root/bin/nginxrelay_client media-key web.test.test 192.0.2.10' }, owner => 'root:root', mode => '0600' },
        'and the media key, which works only from the address of the guest, lands at its own path'
    );
    is( $relay->media_key_path('web.test.test'), '/etc/ssl/nginxrelay/web.test.test.media.key.b64', 'which is apart from the ban key' );

    %files = $relay->issue_grant( $grant, upstreams => { tls => '192.0.2.10:8443', http => '192.0.2.10:8080' }, names => ['public.web.test.test'], media => [] );
    ok( !exists $files{ $relay->media_key_path('web.test.test') }, 'a guest with no media name gets no media key' );
};

subtest 'bin/destroy releases them by the same script' => sub {
    my %revocation = $relay->revoke_grant( { recipe => 'nginxrelay', guest => 'relay.test.test', client => 'web.test.test' } );
    is( $revocation{command}, '/root/bin/nginxrelay_client release web.test.test', 'nginxrelay_client release, for the domain' );
    like( $revocation{stays}, qr/Run[ ]\Q$revocation{command}\E[ ]there/, 'and a relay that is not up is told the same command' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
