#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-RelayRecipe.t - what every relay shares: its host key, where its
ban keys land, and the one directive of sshd that reads them

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};

use FindBin::libs;

use Provisioner::Cookbook();

# A relay that says nothing of its own.
package Bare::Relay {
    use parent qw{Provisioner::RelayRecipe};
    sub recipe_name { return 'barerelay' }
}

subtest 'a relay must say where its registrations are, and which ports a ban closes' => sub {
    my $must = qr/\ABare::Relay[ ]is[ ]a[ ]relay,[ ]so[ ]it[ ]must[ ]say/;
    like( exception { Bare::Relay->relay_dir },    qr/$must[ ]where/,         'the directory' );
    like( exception { Bare::Relay->banned_ports }, qr/$must[ ]which[ ]ports/, 'and the ports' );
};

subtest 'each relay has its own set of bans, and its own files on the guests behind it' => sub {
    is( Bare::Relay->ban_set,                        'barerelay-bans',                                 'the set is named for the recipe' );
    is( Bare::Relay->key_path('web.test.test'),      '/etc/fail2ban/barerelay/web.test.test.key.b64',  'so is the directory of the ban key on the guest' );
    is( Bare::Relay->host_key_path('web.test.test'), '/etc/fail2ban/barerelay/web.test.test.host.b64', 'and of the host key that it pins' );

    my $grant = { recipe => 'barerelay', guest => 'relay.test.test', client => 'web.test.test' };
    like( exception { Bare::Relay->issue_grant($grant) }, qr/must[ ]say[ ]what[ ]it[ ]issues/, 'a relay must say what it issues to a guest that registers' );

    my $relay = Test::MockModule->new( 'Bare::Relay', no_auto => 1 );
    $relay->define( registration_files => sub { return ( '/bogus/registration' => { issue => { guest => 'relay.test.test', command => 'bogus' } } ) } );
    my %file = Bare::Relay->issue_grant($grant);
    is_deeply( [ sort keys %file ], [qw{/bogus/registration /etc/fail2ban/barerelay/web.test.test.host.b64}], 'and the relay adds its host key to that' );
    is_deeply(
        $file{'/etc/fail2ban/barerelay/web.test.test.host.b64'}{issue},
        { guest => 'relay.test.test', command => 'base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub' },
        'which it issues from its own public key'
    );
};

subtest 'every relay names the one host key of the guest' => sub {
    my %bare  = Bare::Relay->guest_secrets( '/bogus', 'relay.test.test' );
    my %nginx = Provisioner::Cookbook->load('nginxrelay')->guest_secrets( '/bogus', 'relay.test.test' );
    is( $bare{'/etc/ssh/ssh_host_ed25519_key'}{ref},  'secret:relay/relay.test.test-ssh-host-key/password', 'from an entry of the store that no recipe owns' );
    is( $nginx{'/etc/ssh/ssh_host_ed25519_key'}{ref}, $bare{'/etc/ssh/ssh_host_ed25519_key'}{ref},          'so two relays on one guest pin one key' );
};

subtest 'sshd reads the keys of every relay of the guest from one directive' => sub {
    my $nginxrelay = Provisioner::Cookbook->load('nginxrelay');
    my %opts       = $nginxrelay->enrich( modules => [qw{ubuntu nginx nginxrelay}] );
    is_deeply( $opts{relay_dirs}, ['/etc/nginx/nginxrelay.d'], 'the directory of each relay, and of nothing else on the guest' );
    is( $opts{ban_set}, 'nginxrelay-bans', 'with the set' );
    is_deeply( $opts{banned_ports}, [ 80, 4443 ], 'and the ports that a ban closes' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
