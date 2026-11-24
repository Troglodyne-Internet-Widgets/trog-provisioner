#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
no autovivification;

=head1 NAME

t/skills-ask-guest.t - ask_guest, of the provisioning-recipes skill: what it
refuses, and what it sends a guest

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use Capture::Tiny    qw{capture_stdout};
use File::Slurper::Temp();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

require_ok("$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts/ask_guest")
  or BAIL_OUT('ask_guest does not load');

# Enough of a fleet and a hypervisor to reach the key and the guest.  They are
# mocked in Trog::Hypervisors and Trog::HV rather than in the script's own
# package, which is required by path and so is not on @INC for MockModule.
{

    package FakeFleet;
    sub configured { return 0 }

    package FakeHV;
    sub domain_dir         { return '/bogus/domains' }
    sub inspection_address { return '192.0.2.10' }
    sub describe           { return 'a fake hypervisor' }

    package FakeGuest;
    sub capture_sudo { my ( $self, @argv ) = @_; $self->{sent} = [@argv]; return "said\n" }
}

my $fleet = Test::MockModule->new('Trog::Hypervisors');
$fleet->redefine( load => sub { return bless {}, 'FakeFleet' } );
my $hv = Test::MockModule->new('Trog::HV');
$hv->redefine( new => sub { return bless {}, 'FakeHV' } );

subtest 'a domain without a command is refused with the usage' => sub {
    like( exception { Trog::Skill::AskGuest::main('vm.test') }, qr/Usage: \s+ ask_guest \s+ \[--agent\] \s+ DOMAIN \s+ COMMAND/, 'names what it takes' );
};

subtest 'a key the store never gave up is said so, rather than handed to ssh as nothing' => sub {
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { return undef } );

    my $err = exception { Trog::Skill::AskGuest::main( 'vm.test', 'true' ) };
    like( $err, qr/No \s+ key \s+ for \s+ vm[.]test/,   'names the domain it has no key for' );
    like( $err, qr/password \s+ goes \s+ on \s+ stdin/, 'and says how to give the store one' );
    like( $err, qr/ask_guest \s+ --agent/,              'or how to log in through the ssh agent' );
};

subtest '--agent logs in through the ssh agent, and never asks the store for the key' => sub {
    local $ENV{SSH_AUTH_SOCK} = '/bogus/agent.sock';
    my ( $sent, %built ) = ( bless {}, 'FakeGuest' );
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { die "key_path was asked, which opens the store\n" } );
    $guest->redefine( new      => sub { ( undef, %built ) = @_; return $sent } );

    my $err = exception {
        capture_stdout { Trog::Skill::AskGuest::main(qw{--agent vm.test true}) }
    };
    is( $err, undef, 'the store is never asked for the key' )                                       or diag $err;
    ok( !exists $built{key_path}, 'and the guest has no key, so ssh offers the keys of the agent' ) or diag explain \%built;
    is_deeply( $sent->{sent}, [qw{sh -c true}], 'and the command reaches it' );

    delete local $ENV{SSH_AUTH_SOCK};
    like( exception { Trog::Skill::AskGuest::main(qw{--agent vm.test true}) }, qr/SSH_AUTH_SOCK \s+ is \s+ not \s+ set/, 'with no agent, --agent is refused' );
};

# A getaddrinfo that knows the names of %$known.
sub resolver {
    my ($known) = @_;
    return sub {
        my $ip = $known->{ $_[0] } or return ('Name or service not known');
        return ( q{}, { family => Socket::AF_INET(), socktype => Socket::SOCK_STREAM(), protocol => 0, addr => Socket::pack_sockaddr_in( 0, Socket::inet_aton($ip) ), canonname => undef } );
    };
}

subtest 'a guest that nothing runs at an address, and whose name does not resolve, is said so' => sub {
    my $nowhere = Test::MockModule->new( 'FakeHV', no_auto => 1 );
    $nowhere->redefine( inspection_address => sub { return } );
    my $socket = Test::MockModule->new('Socket');
    $socket->redefine( getaddrinfo => resolver( {} ) );

    like( exception { Trog::Skill::AskGuest::main( 'vm.test', 'true' ) }, qr/nothing[ ]to[ ]ask/, 'rather than ssh being handed no host' );
};

subtest 'a guest that no hypervisor can say the address of is asked at the address of its name' => sub {
    local $ENV{SSH_AUTH_SOCK} = '/bogus/agent.sock';
    my $unasked = Test::MockModule->new( 'FakeHV', no_auto => 1 );
    $unasked->redefine( inspection_address => sub { die "Nothing was typed for the store\n" } );
    my $socket = Test::MockModule->new('Socket');
    $socket->redefine( getaddrinfo => resolver( { 'vm.test' => '192.0.2.11' } ) );
    my ( $sent, %built ) = ( bless {}, 'FakeGuest' );
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( new => sub { ( undef, %built ) = @_; return $sent } );

    my $warned = q{};
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    capture_stdout { Trog::Skill::AskGuest::main(qw{--agent vm.test true}) };
    is( $built{host}, '192.0.2.11', 'the address that its name resolves to' );
    is_deeply( $sent->{sent}, [qw{sh -c true}], 'and the command reaches it' );
    like( $warned, qr/Nothing \s+ was \s+ typed/,                          'and it says why the hypervisor could not say' );
    like( $warned, qr/vm[.]test \s+ resolves \s+ to \s+ 192[.]0[.]2[.]11/, 'and where it went instead' );
};

subtest 'the command reaches the guest whole, quotes and all' => sub {
    my $sent  = bless {}, 'FakeGuest';
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { return '/bogus/key.rsa' } );
    $guest->redefine( new      => sub { return $sent } );

    my $said = capture_stdout { Trog::Skill::AskGuest::main( 'vm.test', q{awk '{print $1}'}, '/etc/hosts' ) };
    is_deeply( $sent->{sent}, [ qw{sh -c}, q{awk '{print $1}' /etc/hosts} ], 'as root, as one argument of sh -c, with its own quotes left alone' );
    is( $said, "said\n", 'and what the guest said is printed' );
};

subtest 'a domain that shares the guest of another is asked of that guest' => sub {
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", "_shared:\n    host.test.test:\n        - tenant.test.test\n" );

    my ( @addressed, @keyed );
    my $sent    = bless {}, 'FakeGuest';
    my $address = Test::MockModule->new( 'FakeHV', no_auto => 1 );
    $address->redefine( inspection_address => sub { push( @addressed, $_[1] ); return '192.0.2.10' } );
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { push( @keyed, $_[1] ); return '/bogus/key.rsa' } );
    $guest->redefine( new      => sub { return $sent } );

    capture_stdout { Trog::Skill::AskGuest::main( 'tenant.test.test', 'true' ) };
    is_deeply( \@addressed,   ['host.test.test'], 'the address is of the host' );
    is_deeply( \@keyed,       ['host.test.test'], 'and so is the key' );
    is_deeply( $sent->{sent}, [qw{sh -c true}],   'and the command reaches it' );

    local $ENV{SSH_AUTH_SOCK} = '/bogus/agent.sock';
    my %built;
    $guest->redefine( new => sub { ( undef, %built ) = @_; return $sent } );
    @addressed = ();
    capture_stdout { Trog::Skill::AskGuest::main(qw{--agent tenant.test.test true}) };
    is_deeply( \@addressed, ['host.test.test'], 'with --agent, the address is of the host too' );
    is( $built{name}, 'host.test.test', 'and so is the guest it logs in to' );
};

subtest 'the guest is reached at its address, whatever its internal name, with the key of the store or with --agent' => sub {
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", "_base:\n    _global: {}\nrelayed.test.test:\n    _global:\n        internal_name: guest.relayed.test.test\n" );
    Provisioner::Cookbook->forget();

    my ( @made, @keyed );
    my $sent  = bless {}, 'FakeGuest';
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { push( @keyed, $_[1] ); return '/bogus/key.rsa' } );
    $guest->redefine( new => sub { my ( undef, %args ) = @_; push( @made, \%args ); return $sent } );

    capture_stdout { Trog::Skill::AskGuest::main( 'relayed.test.test', 'true' ) };
    is( $made[-1]{host},     '192.0.2.10',     'the address from the hypervisor, which needs no record in DNS' );
    is( $made[-1]{key_path}, '/bogus/key.rsa', 'with the key of the store' );

    @keyed = ();
    local $ENV{SSH_AUTH_SOCK} = '/bogus/agent.sock';
    capture_stdout { Trog::Skill::AskGuest::main(qw{--agent relayed.test.test true}) };
    is( $made[-1]{host}, '192.0.2.10', 'with --agent, it is the address too' );
    is_deeply( \@keyed, [], 'and the store is not asked for a key' );
    ok( !defined $made[-1]{key_path}, 'the guest is given none, so ssh uses the agent' );
};

done_testing();
