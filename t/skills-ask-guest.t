#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

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

subtest 'a guest that nothing runs at an address is said so' => sub {
    my $nowhere = Test::MockModule->new( 'FakeHV', no_auto => 1 );
    $nowhere->redefine( inspection_address => sub { return } );

    like( exception { Trog::Skill::AskGuest::main( 'vm.test', 'true' ) }, qr/nothing[ ]to[ ]ask/, 'rather than ssh being handed no host' );
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

done_testing();
