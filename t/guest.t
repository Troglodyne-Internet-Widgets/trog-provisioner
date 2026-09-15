#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/guest.t - Trog::Guest: what a freshly built guest has to be waited for

=cut

use Test::More;
use Test::Fatal   qw{exception};
use Capture::Tiny qw{capture_stdout};
use File::Temp();
use Test::MockModule qw{strict};
use Test::NoWarnings;
use File::Slurper();
use File::Slurper::Temp();
use Trog::Config();
use Trog::Secrets();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it
use Trog::Guest();

my $DOMAIN = 'vm.test.test';
my $KEY    = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----";

# A guest and a hypervisor reach their far side the same way, so the transport
# is Trog::Machine's and is tested in t/hv.t.  What is here is the rest.

subtest 'a guest needs somewhere to connect to' => sub {
    like( exception { Trog::Guest->new( user => 'ubuntu' ) }, qr/needs[ ]a[ ]host/, 'refuses to be built without one' );
};

subtest 'identity' => sub {
    my $guest = Trog::Guest->new(
        name => 'vm.example.test', host     => '203.0.113.10',
        user => 'ubuntu',          key_path => '/opt/domains/vm.example.test/key.rsa'
    );

    is( $guest->name,       'vm.example.test',     'name' );
    is( $guest->ssh_host,   '203.0.113.10',        'host' );
    is( $guest->ssh_user,   'ubuntu',              'user' );
    is( $guest->ssh_port,   22,                    'the usual port' );
    is( $guest->ssh_target, 'ubuntu@203.0.113.10', 'ssh target' );
    ok( !$guest->is_local, 'a guest is never us' );
    is( $guest->describe, 'vm.example.test (ubuntu@203.0.113.10)', 'says both in errors' );

    is(
        Trog::Guest->new( host => '203.0.113.11' )->name, '203.0.113.11',
        'an unnamed guest answers to its address'
    );
};

# --- Waiting ------------------------------------------------------------------
subtest 'wait_for_ssh wants the port open and the connection made' => sub {
    my $guest = Trog::Guest->new( name => 'vm.example.test', host => '203.0.113.10', user => 'ubuntu' );

    my $ports   = Test::MockModule->new('Net::EmptyPort');
    my $machine = Test::MockModule->new('Trog::Machine');

    $ports->redefine( wait_port => sub { 0 } );
    my $err = exception {
        quietly( sub { $guest->wait_for_ssh( timeout => 1 ) } )
    };
    like( $err, qr/never[ ]came[ ]up[ ]after[ ]1s/, 'a port that never opens is an error' );
    like( $err, qr/vm\.example\.test/,              'naming the guest' );

    # A port that opens but a connection that will not: checking only the first
    # is how you get a confusing failure three steps later.
    $ports->redefine( wait_port => sub { 1 } );
    $machine->redefine( ssh => sub { undef } );
    like(
        exception {
            quietly( sub { $guest->wait_for_ssh } )
        },
        qr/Could[ ]not[ ]establish[ ]an[ ]SSH[ ]connection/,
        'and so is that'
    );

    $machine->redefine( ssh => sub { bless {}, 'FakeSSH' } );
    is( quietly( sub { $guest->wait_for_ssh } ), $guest, 'otherwise we get the guest back' );
};

subtest 'wait_for_cloud_init re-runs the modules that failed' => sub {
    my $guest = Trog::Guest->new( name => 'vm.example.test', host => '203.0.113.10', user => 'ubuntu' );

    my @ran;
    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( run_cmd  => sub { my ( $s, @c ) = @_; push @ran, join( ' ', @c );           return 0 } );
    $machine->redefine( run_sudo => sub { my ( $s, @c ) = @_; push @ran, 'sudo ' . join( ' ', @c ); return 0 } );
    $machine->redefine(
        capture_cmd => sub {
            my ( $s, $cmd ) = @_;
            push @ran, $cmd;
            return '[{"name":"modules-final/config-foo","result":"FAIL"},' . '{"name":"modules-config/config-bar","result":"SUCCESS"}]'
              if index( $cmd, 'analyze dump' ) >= 0;
            return 're-ran it';
        }
    );

    ok( quietly( sub { $guest->wait_for_cloud_init('vm.example.test') } ), 'finishes' );

    ok( ( grep { index( $_, 'Boot configuration complete' ) >= 0 } @ran ), 'waited for the boot to report complete' );
    ok(
        ( grep { index( $_, 'sudo rm /var/lib/cloud/instances/vm.example.test/sem/config_foo' ) >= 0 } @ran ),
        'removed the semaphore of the module that failed'
    );
    ok( ( grep { index( $_,  'cloud-init single --name foo' ) >= 0 } @ran ), 'and re-ran it' );
    ok( !( grep { index( $_, '--name bar' ) >= 0 } @ran ),                   'left the one that succeeded alone' );
};

subtest 'a cloud-init that reports failure is fatal' => sub {
    my $guest = Trog::Guest->new( host => '203.0.113.10', user => 'ubuntu' );

    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( run_cmd     => sub { 1 } );
    $machine->redefine( run_sudo    => sub { 1 } );
    $machine->redefine( capture_cmd => sub { '[]' } );

    like(
        exception {
            quietly( sub { $guest->wait_for_cloud_init('vm.example.test') } )
        },
        qr/Cloud[ ]init[ ]reported[ ]failure/,
        'dies'
    );
};

subtest 'cloud-init that does not return JSON is fatal' => sub {
    my $guest = Trog::Guest->new( host => '203.0.113.10', user => 'ubuntu' );

    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( run_cmd     => sub { 0 } );
    $machine->redefine( run_sudo    => sub { 0 } );
    $machine->redefine( capture_cmd => sub { 'command not found' } );

    like(
        exception {
            quietly( sub { $guest->wait_for_cloud_init('vm.example.test') } )
        },
        qr/did[ ]not[ ]return[ ]a[ ]JSON[ ]array/,
        'dies rather than carrying on blind'
    );
};

subtest 'wait_for_makefile waits for the queue twice' => sub {
    my $guest = Trog::Guest->new( name => 'vm.example.test', host => '203.0.113.10', user => 'ubuntu' );

    my @ran;
    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( run_cmd     => sub { my ( $s, @c ) = @_; push @ran, join( ' ', @c );           return 0 } );
    $machine->redefine( run_sudo    => sub { my ( $s, @c ) = @_; push @ran, 'sudo ' . join( ' ', @c ); return 0 } );
    $machine->redefine( capture_cmd => sub { my ( $s, $cmd ) = @_; return $cmd =~ m/setup[.]status/ ? "0\n" : 'the last few lines' } );

    ok( quietly( sub { $guest->wait_for_makefile('vm.example.test') } ), 'finishes' );

    my @queue = grep { index( $_, 'atq' ) >= 0 } @ran;
    is( scalar @queue, 2, 'twice, because the Makefile may queue work of its own' );
    ok( ( grep { index( $_, 'until [ -f /var/log/vm.example.test.setup.log ]' ) >= 0 } @ran ),      'waited for the log to appear' );
    ok( ( grep { index( $_, 'while lsof | grep /var/log/vm.example.test.setup.log' ) >= 0 } @ran ), 'and to stop being written' );
    ok( ( grep { index( $_, 'until [ -f /var/log/vm.example.test.setup.status' ) >= 0 } @ran ),     'and for the result to be recorded' );
};

# make's exit code is lost to the pipe that tees the log, so setup.sh writes it
# to a file of its own.  Without reading it this returned 1 whatever happened,
# and a guest whose build died was provisioned "successfully".
subtest 'a build make failed is not a build that finished' => sub {
    my $guest = Trog::Guest->new( name => 'vm.example.test', host => '203.0.113.10', user => 'ubuntu' );

    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( run_cmd  => sub { 0 } );
    $machine->redefine( run_sudo => sub { 0 } );

    foreach my $case ( [ "2\n", 'make exited 2' ], [ "1\n", 'make exited 1' ], [ q{}, 'nothing recorded a result' ] ) {
        my ( $recorded, $desc ) = @$case;
        $machine->redefine( capture_cmd => sub { my ( $s, $cmd ) = @_; return $cmd =~ m/setup[.]status/ ? $recorded : 'the last few lines' } );
        ok( !quietly( sub { $guest->wait_for_makefile('vm.example.test') } ), "false when $desc" );
    }

    $machine->redefine( capture_cmd => sub { my ( $s, $cmd ) = @_; return $cmd =~ m/setup[.]status/ ? "0\n" : 'the last few lines' } );
    ok( quietly( sub { $guest->wait_for_makefile('vm.example.test') } ), 'and true when it exited zero' );
};

# These print their progress; the tests do not need to read it.
sub quietly {
    my ($code) = @_;
    my ( undef, @result ) = capture_stdout { $code->() };
    return wantarray ? @result : $result[0];
}

subtest 'the hang detector allows the setup timeout it is wrapping' => sub {

    # These are two separate limits on the same wait, and only their
    # relationship matters.  wait_for_makefile blocks on the at queue for
    # $SETUP_TIMEOUT; every remote command it uses to do that goes through
    # Trog::Machine::_unhang, which used to allow ten minutes flat.  The inner
    # limit won, so SETUP_TIMEOUT did nothing whatever it was set to, and a
    # guest that was still building was reported as a failed provision.
    #
    # Each limit was defensible alone, which is why this survived: the bug is
    # only visible when the two are considered together.
    require Trog::Machine;

    my %seconds = ( s => 1, m => 60, h => 3600 );
    my ( $n, $unit ) = $Trog::Guest::SETUP_TIMEOUT =~ m/\A(\d+)([smh]?)\z/;
    ok( $n, "SETUP_TIMEOUT parses ($Trog::Guest::SETUP_TIMEOUT)" );
    my $setup = $n * ( $seconds{ $unit || 's' } // 1 );

    # Built the way wait_for_makefile builds it.
    my $atq = qq{sudo timeout $Trog::Guest::SETUP_TIMEOUT bash -c 'until [ \$(atq | wc -l) = 0 ]; do sleep 1; done;'};

    cmp_ok(
        Trog::Machine::_hang_limit($atq), '>=', $setup,    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        'the hang detector gives the wait at least as long as the wait asks for'
    );
};

subtest 'the reference is keyed on the domain' => sub {

    # One entry per guest: two domains must not answer to each other's key, and
    # a group of its own keeps them out of the way of what an operator wrote.
    is( Trog::Guest->ref_for_key($DOMAIN), 'secret:guests/vm.test.test/password', 'named for the domain' );
    isnt( Trog::Guest->ref_for_key('other.test.test'), Trog::Guest->ref_for_key($DOMAIN), 'and no two share one' );
};

subtest 'a key still on disk is the one used, and nothing is asked for' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/key.rsa", "$KEY\n" );

    # An installation whose domains were provisioned before this existed keeps
    # working, and seals itself one domain at a time as each is rebuilt.  If it
    # did not, every one of them would be unreachable until it was.
    my $creds = Test::MockModule->new('Trog::Credentials');
    $creds->redefine( prompt => sub { die "asked for a password when the key was on disk\n" } );

    is( Trog::Guest->key_path( $DOMAIN, "$dir/key.rsa" ), "$dir/key.rsa", 'the file is the answer' );
};

subtest 'no store means no key and no prompt' => sub {

    # The failure this is really about is a wait, not a refusal.  A prompt in a
    # run with nobody to type at hangs until something kills it, and that is how
    # the suite behaved the first time this was wired up: every test that
    # reached for a key sat waiting on a password for a database that was not
    # there.
    my $creds = Test::MockModule->new('Trog::Credentials');
    $creds->redefine( prompt => sub { die "asked for a password with no store to open\n" } );

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- asserting the store is absent, which is the case under test
    ok( !-f Trog::Config->path('secrets.kdbx'), 'there is no store in this configuration' );
    is( Trog::Guest->key_path( $DOMAIN, "/bogus/nothing/key.rsa" ), undef, 'so there is no key, and nothing was asked' );
};

subtest 'sealing with no store asks for nothing and leaves the key where it is' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/key.rsa", "$KEY\n" );

    # The other half of the wait path() was guarded against.  seal is the one
    # bin/new_config reaches on every generate, and it had no guard at all.
    my $creds = Test::MockModule->new('Trog::Credentials');
    $creds->redefine( prompt => sub { die "asked for a password with no store to write into\n" } );

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- asserting the store is absent, which is the case under test
    ok( !-f Trog::Config->path('secrets.kdbx'), 'there is no store in this configuration' );
    is( Trog::Guest->seal_key( $DOMAIN, "$dir/key.rsa" ), 0, 'sealing does nothing, and nothing was asked' );
    ok( -f "$dir/key.rsa", 'and the key is still on the disk it was on' );
};

subtest 'sealing puts it in the store and takes it off the disk' => sub {
    my $dir   = File::Temp::tempdir( CLEANUP => 1 );
    my $store = "$dir/secrets.kdbx";
    File::Slurper::Temp::write_text( "$dir/key.rsa", "$KEY\n" );

    # A real store with somebody else's secret already in it.  Sealing used to
    # go through Trog::Secrets::create, which builds a new database out of what
    # it is handed -- so this entry is the one that would have disappeared.
    Trog::Secrets->create( $store, 'hunter2', 'secret:registrar/easydns/password' => 'REGISTRAR' );

    my $asked = 0;
    my $creds = Test::MockModule->new('Trog::Credentials');
    $creds->redefine( prompt => sub { $asked++; return 'hunter2' } );
    my $conf = Test::MockModule->new('Trog::Config');
    $conf->redefine( path => sub { return $store } );

    ok( Trog::Guest->seal_key( $DOMAIN, "$dir/key.rsa" ), 'it seals' );

    my %after = Trog::Secrets->lookup(
        $store, 'hunter2',
        key       => Trog::Guest->ref_for_key($DOMAIN),
        registrar => 'secret:registrar/easydns/password',
    );
    is( $after{key},       "$KEY\n",    'the whole key went in, newlines and all' );
    is( $after{registrar}, 'REGISTRAR', 'and the secret that was already there is still there' );
    ok( !-e "$dir/key.rsa", 'and the file is gone' );

    # write rather than remember: the key is rotated on every real provision, so
    # the store has to hold the current one.  remember keeps the first answer
    # forever, which would quietly turn a per-provision key into a standing one.
    is( $asked, 1, 'the password was wanted once' );
};

subtest 'sealing nothing is not sealing' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );

    my $secrets = Test::MockModule->new('Trog::Secrets');
    $secrets->redefine( create => sub { die "wrote an empty key into the store\n" } );

    # A dry run leaves no key to seal, and a domain that has never been built
    # has none either.  Writing an empty value would be worse than doing
    # nothing: the store would then answer with it.
    ok( !Trog::Guest->seal_key( $DOMAIN, "$dir/nothing-here" ), 'a key that is not there does not get sealed' );
};

subtest 'a sealed key is fetched once and lands somewhere private' => sub {
    my $store = Trog::Config->path('secrets.kdbx');
    File::Slurper::Temp::write_binary( $store, 'pretend this is a kdbx' );

    my $reads = 0;
    my $creds = Test::MockModule->new('Trog::Credentials');
    $creds->redefine( prompt => sub { return 'hunter2' } );
    my $secrets = Test::MockModule->new('Trog::Secrets');
    $secrets->redefine( lookup => sub { $reads++; return ( key => $KEY ) } );

    my $path = Trog::Guest->key_path( 'fetched.test.test', '/bogus/nothing/key.rsa' );
    ok( defined $path, 'a path comes back' ) or return;

    is( File::Slurper::read_text($path), "$KEY\n", 'holding the key, with the trailing newline ssh wants' );

    # 0600, because this is the credential for a machine and it is now sitting
    # in a world-readable directory.
    my @stat = stat($path);
    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    is( sprintf( '%04o', $stat[2] & 07777 ), '0600', 'readable by nobody else' );

    # Asked for twice in a run it is fetched once: every guest this touches
    # would otherwise mean another decryption of the database.
    Trog::Guest->key_path( 'fetched.test.test', '/bogus/nothing/key.rsa' );
    is( $reads, 1, 'and the store was opened once' );

    unlink $store;
};

Test::NoWarnings::had_no_warnings();

done_testing;
