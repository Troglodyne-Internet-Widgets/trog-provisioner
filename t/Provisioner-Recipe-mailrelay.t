#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-mailrelay.t - the login that a mail relay issues to
another guest, and where the relay listens

=cut

use Test::More;
use Test::NoWarnings;
use Test::MockModule qw{strict};

use FindBin::libs;

use Provisioner::Cookbook();

my $relay = Provisioner::Cookbook->load('mailrelay');

subtest 'a mail guest gets a login on the relay, and loses it' => sub {
    my %grant = ( recipe => 'mailrelay', guest => 'relay.test.test', client => 'web.test.test' );
    my %terms = (
        address   => '192.0.2.10',
        upstreams => { imaps => '192.0.2.10:10993', submissions => '192.0.2.10:10465', pop3s => '192.0.2.10:10995' },
        names     => [qw{web.test.test mail.web.test.test}],
    );
    is_deeply(
        { $relay->issue_grant( \%grant, %terms ) },
        {
            '/etc/postfix/mailrelay/web.test.test.password' => {
                issue => { guest => 'relay.test.test', command => '/root/bin/mailrelay_client register web.test.test 192.0.2.10' },
                owner => 'root:root',
                mode  => '0600',
            },
            '/etc/fail2ban/mailrelay/web.test.test.key.b64' => {
                issue => {
                    guest   => 'relay.test.test',
                    command => '/root/bin/mailrelay_client register-clients web.test.test 192.0.2.10:10993 192.0.2.10:10465 192.0.2.10:10995 web.test.test mail.web.test.test',
                },
                owner => 'root:root',
                mode  => '0600',
            },
            '/etc/fail2ban/mailrelay/web.test.test.host.b64' => {
                issue => { guest => 'relay.test.test', command => 'base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub' },
                owner => 'root:root',
                mode  => '0644',
            },
        },
        'mailrelay_client registers the login and the route in, the password lands where the mail recipe reads it, and the mail clients get their routes, in the order of the services, beside the ban key and the host key of the relay'
    );
    is( $relay->password_path('web.test.test'), '/etc/postfix/mailrelay/web.test.test.password', 'which is the password path of the domain' );

    my %revocation = $relay->revoke_grant( \%grant );
    is( $revocation{command}, '/root/bin/mailrelay_client release web.test.test', 'and bin/destroy removes it by the same script' );
    like( $revocation{stays}, qr/Run[ ]\Q$revocation{command}\E[ ]there/, 'and a relay that is not up is told the same command' );
};

subtest 'the relay listens at the address where the guests reach it, on its port' => sub {
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( holdings => sub { return { guests => '192.0.2.5' } } );
    my %config;
    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( domain_config => sub { my ( undef, $domain ) = @_; return $config{$domain} // {} } );
    $cookbook->redefine( host_of       => sub { return } );

    my %opts = $relay->enrich( domain => 'relay.test.test' );
    is( $opts{relay_address}, '192.0.2.5',       'the relay binds the address in the pool' );
    is( $opts{helo_name},     'relay.test.test', 'and it announces the name of its machine' );
    is_deeply( $opts{client_ports},   { imaps => 993, submissions => 465, pop3s => 995 }, 'the mail clients come in on the ports where TLS starts at once' );
    is_deeply( $opts{upstream_ports}, [ 10465, 10993, 10995 ], 'and go out to the proxy ports of the mail recipe' );
    is_deeply( $opts{banned_ports},   [ 465,   993,   995 ],   'where a ban closes them, but not 25' );
    is( $opts{ban_set}, 'mailrelay-bans', 'in a set of its own' );

    $config{'relay.test.test'} = { mailrelay => { relay_port => 3587 } };
    is( $relay->relay_port_of('relay.test.test'), 3587, 'the port that the relay sets' );
    is( $relay->relay_port_of('other.test.test'), 2587, 'or the default' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
