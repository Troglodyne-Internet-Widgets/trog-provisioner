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
    is_deeply(
        { $relay->issue_grant( \%grant, address => '192.0.2.10' ) },
        {
            '/etc/postfix/mailrelay/web.test.test.password' => {
                issue => { guest => 'relay.test.test', command => '/root/bin/mailrelay_client register web.test.test 192.0.2.10' },
                owner => 'root:root',
                mode  => '0600',
            },
        },
        'mailrelay_client registers the login and the route in to the guest, and the password lands where the mail recipe reads it'
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

    $config{'relay.test.test'} = { mailrelay => { relay_port => 3587 } };
    is( $relay->relay_port_of('relay.test.test'), 3587, 'the port that the relay sets' );
    is( $relay->relay_port_of('other.test.test'), 2587, 'or the default' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
