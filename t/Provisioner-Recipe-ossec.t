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
use IPC::Run3();

use FindBin::libs;
use Provisioner::Cookbook();

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
    my @prepare  = $recipe->remote_prepare();
    my %salvage  = $recipe->remote_files();
    my %restores = $recipe->restores( install_dir => '/bogus', domain => 'logs.test.test' );

    # The commands, run with every path under /var moved into a directory of the test.
    my $prepare_in = sub ($root) {
        my @exits = map {
            ( my $command = $_ ) =~ s{(?=/var/)}{$root}g;
            IPC::Run3::run3( [ '/bin/sh', '-c', $command ], \undef, \my $out, \my $err );
            $? >> 8;
        } @prepare;
        return join( q{,}, @exits );
    };

    my $fresh = File::Temp->newdir();
    is( $prepare_in->($fresh), '0,0', 'a collector that does not run the manager yet has nothing to copy, and that is no failure' );
    ok( !-e "$fresh/var/lib/ossec-salvage", 'and it makes no directory for the salvage, which a failure would leave half made' );

    my $built = File::Temp->newdir();
    make_path( "$built/var/ossec/etc", "$built/var/ossec/queue/rids" );
    File::Slurper::Temp::write_text( "$built/var/ossec/etc/client.keys",           "001 web.test.test any bogus\n" );
    File::Slurper::Temp::write_text( "$built/var/ossec/queue/rids/sender_counter", '0:3136:' );
    is( $prepare_in->($built),                                                 '0,0',                           'a collector that runs the manager copies its keys and its count' );
    is( read_text("$built/var/lib/ossec-salvage/client.keys"),                 "001 web.test.test any bogus\n", 'all of the keys' );
    is( read_text("$built/var/lib/ossec-salvage/sender_counter"),              '0:3136:',                       'and the count of the messages of the manager' );
    is( ( stat "$built/var/lib/ossec-salvage" )[2] & oct('07777'),             oct('0700'),                     'into a directory that only root opens' );
    is( ( stat "$built/var/lib/ossec-salvage/client.keys" )[2] & oct('07777'), oct('0600'),                     'as files that only root reads' );
    is_deeply( \%salvage, { '/var/lib/ossec-salvage/' => 'ossec-salvage/' }, 'and salvages the copies' );
    is_deeply(
        \%restores,
        {
            '/var/ossec/etc/client.keys'           => { from => '/bogus/logs.test.test/ossec-salvage/client.keys',    owner => 'root:ossec',   mode => '0440' },
            '/var/ossec/queue/rids/sender_counter' => { from => '/bogus/logs.test.test/ossec-salvage/sender_counter', owner => 'ossecr:ossec', mode => '0644' },
        },
        'and puts them back from where the salvage lands, the keys for the manager alone and the count for remoted'
    );
};

subtest 'the manager sends above the count that it restored' => sub {
    my $ubuntu   = Provisioner::Cookbook->load( 'ossec', distro => 'ubuntu' )->new( output_dir => '/bogus', libdir => '.', target_packager => 'deb', template_dirs => Provisioner::Cookbook->template_dirs('ubuntu') );
    my $fragment = $ubuntu->render_global( domain => 'logs.test.test', admin_email => 'root@test.test', script_dir => '/bogus/bin' );
    my @raise    = grep { index( $_, '/var/ossec/queue/rids/sender_counter' ) >= 0 } Provisioner::Recipe->fragment_commands($fragment);
    is( scalar @raise, 1, 'one command of the fragment sets the count' ) or return;

    # The command runs under make, as on the guest, with its path moved into a directory of the test.
    my $run_in = sub ($root) {
        ( my $command = $raise[0] ) =~ s{(?=/var/ossec/queue/rids/)}{$root}g;
        File::Slurper::Temp::write_text( "$root/Makefile", "all:\n\t$command" );
        IPC::Run3::run3( [ qw{make -s -C}, $root ], \undef, \my $out, \my $err );
        diag($err) if $?;
        return $? >> 8;
    };

    my $restored = File::Temp->newdir();
    make_path("$restored/var/ossec/queue/rids");
    File::Slurper::Temp::write_text( "$restored/var/ossec/queue/rids/sender_counter", '4:3136:' );
    is( $run_in->($restored),                                       0,      'the command succeeds on a restored count' );
    is( read_text("$restored/var/ossec/queue/rids/sender_counter"), '5:0:', 'and the manager starts at the next global count, above every message that the old manager sent' );

    my $fresh = File::Temp->newdir();
    make_path("$fresh/var/ossec/queue/rids");
    is( $run_in->($fresh), 0, 'a manager that never sent a message has no count, and that is no failure' );
    ok( !-e "$fresh/var/ossec/queue/rids/sender_counter", 'and it gets none, so remoted starts its own' );
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
