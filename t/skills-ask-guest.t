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
    sub capture_cmd { my ( $self, $cmd ) = @_; $self->{sent} = $cmd; return "said\n" }
}

my $fleet = Test::MockModule->new('Trog::Hypervisors');
$fleet->redefine( load => sub { return bless {}, 'FakeFleet' } );
my $hv = Test::MockModule->new('Trog::HV');
$hv->redefine( new => sub { return bless {}, 'FakeHV' } );

subtest 'a domain without a command is refused with the usage' => sub {
    like( exception { Trog::Skill::AskGuest::main('vm.test') }, qr/Usage: \s+ ask_guest \s+ DOMAIN \s+ COMMAND/, 'names what it takes' );
};

subtest 'a key the store never gave up is said so, rather than handed to ssh as nothing' => sub {
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { return undef } );

    my $err = exception { Trog::Skill::AskGuest::main( 'vm.test', 'true' ) };
    like( $err, qr/No \s+ key \s+ for \s+ vm[.]test/,   'names the domain it has no key for' );
    like( $err, qr/password \s+ goes \s+ on \s+ stdin/, 'and says how to give the store one' );
};

subtest 'the command reaches the guest whole, quotes and all' => sub {
    my $sent  = bless {}, 'FakeGuest';
    my $guest = Test::MockModule->new('Trog::Guest');
    $guest->redefine( key_path => sub { return '/bogus/key.rsa' } );
    $guest->redefine( new      => sub { return $sent } );

    my $said = capture_stdout { Trog::Skill::AskGuest::main( 'vm.test', q{awk '{print $1}'}, '/etc/hosts' ) };
    is( $sent->{sent}, q{sudo sh -c 'awk '\''{print $1}'\'' /etc/hosts'}, 'as root, with its own quotes kept inside the quoting' );
    is( $said,         "said\n",                                          'and what the guest said is printed' );
};

done_testing();
