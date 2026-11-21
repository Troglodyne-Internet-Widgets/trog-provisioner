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
use Test::Fatal qw{exception};
use File::Temp();
use File::Path    qw{make_path};
use File::Slurper qw{read_text};
use File::Slurper::Temp();

use FindBin::libs;

use_ok('Provisioner::Recipe::ossec') or BAIL_OUT('Provisioner::Recipe::ossec does not load');

my $recipe = 'Provisioner::Recipe::ossec'->new( output_dir => '/bogus', libdir => '.', target_packager => 'deb' );

subtest 'required_recipes' => sub {
    my %required = $recipe->required_recipes();
    is_deeply( [ sort keys %required ],         [qw{configd logcollector}], 'it needs the collector that it reads and configd, and nothing that draws its alerts' );
    is_deeply( { $required{configd}->() },      { languages    => ['ossec'] },           'configd, with the language that makes ossec.conf' );
    is_deeply( { $required{logcollector}->() }, { forward_text => ['127.0.0.1:10514'] }, 'and asks the collector for a copy as text on the default port' );

    my %moved = $recipe->required_recipes( port => 20514 );
    is_deeply( { $moved{logcollector}->() }, { forward_text => ['127.0.0.1:20514'] }, 'and on the port that the configuration names' );
};

subtest 'listens' => sub {
    is_deeply( [ $recipe->listens() ],                [qw{127.0.0.1:10514 1514/udp}], 'the manager on loopback for the stream, and on every address for the agents' );
    is_deeply( [ $recipe->listens( port => 20514 ) ], [qw{127.0.0.1:20514 1514/udp}], 'on the port that the configuration names' );
};

subtest 'remote_prepare, remote_files and restores' => sub {
    my ($prepare) = $recipe->remote_prepare();
    my %salvage   = $recipe->remote_files();
    my %restores  = $recipe->restores( install_dir => '/bogus', domain => 'logs.test.test' );

    # The command, run with its two paths moved into a directory of the test.
    my $prepare_in = sub ($root) {
        ( my $command = $prepare ) =~ s{(?=/var/(?:ossec/etc/client[.]keys|lib/ossec-salvage))}{$root}g;
        return system( '/bin/sh', '-c', $command );
    };

    my $fresh = File::Temp->newdir();
    is( $prepare_in->($fresh), 0, 'a collector that does not run the manager yet has nothing to copy, and that is no failure' );
    ok( !-e "$fresh/var/lib/ossec-salvage", 'and it makes no directory for the salvage, which a failure would leave half made' );

    my $built = File::Temp->newdir();
    make_path("$built/var/ossec/etc");
    File::Slurper::Temp::write_text( "$built/var/ossec/etc/client.keys", "001 web.test.test any bogus\n" );
    is( $prepare_in->($built),                                                 0,                               'a collector that runs the manager copies its keys' );
    is( read_text("$built/var/lib/ossec-salvage/client.keys"),                 "001 web.test.test any bogus\n", 'all of them' );
    is( ( stat "$built/var/lib/ossec-salvage" )[2] & oct('07777'),             oct('0700'),                     'into a directory that only root opens' );
    is( ( stat "$built/var/lib/ossec-salvage/client.keys" )[2] & oct('07777'), oct('0600'),                     'as a file that only root reads' );
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
    is( $opts{port}, 10514, 'the default port of the manager is the one that required_recipes and listens assume' );

    my $err = exception { $recipe->validate( domain => 'logs.test.test', alerts_port => 10516, datasource => 'InfluxDB' ) };
    like( $err, qr/Properties[ ]not[ ]allowed:[ ]alerts_port,[ ]datasource/, 'a configuration that still names the settings of grafanaossec here is refused, naming them' );
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
    is( $watches->( 'guest.test.test', 'guest.test.test' => { logshipper => { host     => 'plain.test.test' } } ),    1, 'a guest that ships to a collector that does not name the manager is, because logcollector requires it' );
    is( $watches->( 'guest.test.test', 'guest.test.test' => { logshipper => { host     => 'syslog.vendor.test' } } ), 0, 'nor one that ships outside this installation' );

    $conf = { 'logs.test.test' => {%collector}, 'guest.test.test' => {} };
    is( 'Provisioner::Recipe::ossec'->watches('guest.test.test'), 0, 'nor one that ships nowhere' );
};

subtest 'manager_of' => sub {
    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    my $conf     = { _base => { logshipper => { host => 'logs.test.test' } }, 'logs.test.test' => { logcollector => {} }, 'guest.test.test' => {} };
    $cookbook->redefine( configuration => sub { return $conf } );

    is( 'Provisioner::Recipe::ossec'->manager_of('guest.test.test'), 'logs.test.test', 'the collector that the guest ships everything to' );
    is( 'Provisioner::Recipe::ossec'->manager_of('logs.test.test'),  undef,            'and none for the collector, which ships nowhere' );
};

had_no_warnings();
done_testing();
