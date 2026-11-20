#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-ossec.t - the ossec recipe asks the collector for the
stream on the port where the manager reads it, claims both of its ports, and
says which guests its manager watches

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::MockModule();

use FindBin::libs;

use_ok('Provisioner::Recipe::ossec') or BAIL_OUT('Provisioner::Recipe::ossec does not load');

my $recipe = 'Provisioner::Recipe::ossec'->new( output_dir => '/bogus', libdir => '.', target_packager => 'deb' );

subtest 'required_recipes' => sub {
    my %required = $recipe->required_recipes();
    ok( exists $required{grafanasyslog}, 'it needs grafanasyslog, which installs telegraf and grafana' );
    is_deeply( { $required{configd}->() },      { languages    => ['ossec'] },           'and configd, with the language that makes ossec.conf' );
    is_deeply( { $required{logcollector}->() }, { forward_text => ['127.0.0.1:10514'] }, 'and asks the collector for a copy as text on the default port' );

    my %moved = $recipe->required_recipes( port => 20514 );
    is_deeply( { $moved{logcollector}->() }, { forward_text => ['127.0.0.1:20514'] }, 'and on the port that the configuration names' );
};

subtest 'listens' => sub {
    is_deeply( [ $recipe->listens() ],                                      [qw{127.0.0.1:10514 127.0.0.1:10516/udp 1514/udp}], 'the manager on TCP and telegraf on UDP, both on loopback, and the agents on every address' );
    is_deeply( [ $recipe->listens( port => 20514, alerts_port => 20516 ) ], [qw{127.0.0.1:20514 127.0.0.1:20516/udp 1514/udp}], 'on the ports that the configuration names' );
};

subtest 'remote_prepare, remote_files and restores' => sub {
    my ($prepare) = $recipe->remote_prepare();
    my %salvage   = $recipe->remote_files();
    my %restores  = $recipe->restores( install_dir => '/bogus', domain => 'logs.test.test' );
    is(
        $prepare,
        'install -d -m 0700 /var/lib/ossec-salvage && install -m 0600 /var/ossec/etc/client.keys /var/lib/ossec-salvage/client.keys',
        'a rebuild of the collector copies the keys of the agents for root alone'
    );
    is_deeply( \%salvage, { '/var/lib/ossec-salvage/' => 'ossec-salvage/' }, 'and salvages the copy' );
    is_deeply(
        \%restores,
        { '/var/ossec/etc/client.keys' => { from => '/bogus/logs.test.test/ossec-salvage/client.keys', owner => 'root:ossec', mode => '0440' } },
        'and puts them back from where the salvage lands, for the manager alone'
    );
};

subtest 'issue_grant and revoke_grant' => sub {
    my $grant = { recipe => 'ossec', guest => 'logs.test.test', client => 'guest.test.test' };

    is_deeply(
        { $recipe->issue_grant($grant) },
        {
            '/etc/ossec-client.keys.b64' => {
                issue => { guest => 'logs.test.test', command => '/usr/local/sbin/ossec-agent-key guest.test.test' },
                owner => 'root:root',
                mode  => '0600',
            },
        },
        'the manager issues the key of the agent of the client, for root alone, which the build of the agent decodes'
    );

    my %revocation = $recipe->revoke_grant($grant);
    is( $revocation{command}, '/usr/local/sbin/ossec-agent-revoke guest.test.test', 'and removes the agent of the client when it goes away' );
    like( $revocation{stays}, qr/ossec-agent-revoke[ ]guest\.test\.test/, 'and says how to remove it by hand when the manager is down' );
};

subtest 'args' => sub {
    my %opts = $recipe->validate();
    is( $opts{port},        10514, 'the default port of the manager is the one that required_recipes and listens assume' );
    is( $opts{alerts_port}, 10516, 'and so is the default port of the alerts' );
};

subtest 'watches' => sub {
    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    my $conf;
    $cookbook->redefine( configuration => sub { return $conf } );

    my %collector = ( logcollector => {}, ossec => {} );
    my $watches   = sub {
        my ( $domain, %extra ) = @_;
        $conf = {
            _base              => { logshipper => { host => 'logs.test.test' } },
            'logs.test.test'   => {%collector},
            'plain.test.test'  => { logcollector => {} },
            'guest.test.test'  => {},
            'host.test.test'   => {},
            'tenant.test.test' => {},
            _shared            => { 'host.test.test' => ['tenant.test.test'] },
            %extra,
        };
        return 'Provisioner::Recipe::ossec'->watches($domain);
    };

    is( $watches->('guest.test.test'),                                                                        1, 'a guest that ships everything to a collector with a manager is watched' );
    is( $watches->( 'tenant.test.test', 'host.test.test' => { logshipper => { host => 'logs.test.test' } } ), 1, 'and so is a domain on its machine' );
    is( $watches->('logs.test.test'),                                                                         0, 'the collector is not, because it ships nowhere' );

    is(
        $watches->( 'guest.test.test', 'guest.test.test' => { logshipper => { selector => '*.warn;auth,authpriv.*' } } ),
        0, 'a guest that ships only some facilities is not watched'
    );
    is( $watches->( 'guest.test.test', 'guest.test.test' => { logshipper => { selector => '*.*' } } ),                1, 'but one that names the default selector is' );
    is( $watches->( 'guest.test.test', 'guest.test.test' => { logshipper => { host     => 'plain.test.test' } } ),    0, 'a guest that ships to a collector with no manager is not' );
    is( $watches->( 'guest.test.test', 'guest.test.test' => { logshipper => { host     => 'syslog.vendor.test' } } ), 0, 'nor one that ships outside this installation' );

    $conf = { 'logs.test.test' => {%collector}, 'guest.test.test' => {} };
    is( 'Provisioner::Recipe::ossec'->watches('guest.test.test'), 0, 'nor one that ships nowhere' );
};

had_no_warnings();
done_testing();
