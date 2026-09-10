#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-logshipper.t - where a guest is told to send its logs, and
what it does when told to send them to itself

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();

my $DOMAIN = 'web.test.test';

sub generated {
    my (%extra) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'logshipper', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    my %vars = (
        domain      => $DOMAIN,
        install_dir => '/opt/domains',
        script_dir  => '/root/bin',
        host        => 'logs.test.test',

        # What bin/new_config hands over as the ip pool's assignments, which is
        # how a destination named by bare domain is resolved to an address.
        ipmap => { 'logs.test.test' => '192.168.1.9' },
        %extra,
    );

    $recipe->generate_files( $dir, %vars );
    return ( $dir, $recipe, \%vars );
}

sub conf { my ($dir) = @_; return File::Slurper::read_text("$dir/logshipper.conf") }

subtest 'a destination the pool knows is pinned to its address' => sub {
    my ($dir) = generated();

    # An address, not the name.  The logs that would tell you DNS is broken
    # should not need DNS to arrive.
    like( conf($dir), qr/\Qtarget="192.168.1.9"\E/, 'resolved out of the ip pool' );
    like( conf($dir), qr/\Qport="514"\E/,           'on the default syslog port' );
    like( conf($dir), qr/\Qprotocol="tcp"\E/,       'over tcp, which can be checked for' );
    like( conf($dir), qr/\A\Q*.*\E\s/,              'forwarding everything by default' );
};

subtest 'a destination the pool does not know is used as written' => sub {
    my ($dir) = generated( host => 'syslog.vendor.example' );

    # Not fatal, unlike the mirror: this runs from the makefile, where the guest
    # has resolvers, so an external destination named by DNS is a real thing to
    # want rather than a mistake.
    like( conf($dir), qr/\Qtarget="syslog.vendor.example"\E/, 'passed through' );
};

subtest 'the three constants that were hardcoded are settings now' => sub {
    my ($dir) = generated( port => 5514, protocol => 'udp', selector => '*.warn;auth,authpriv.*' );

    like( conf($dir), qr/\Qport="5514"\E/,              'the port' );
    like( conf($dir), qr/\Qprotocol="udp"\E/,           'the protocol' );
    like( conf($dir), qr/\A\Q*.warn;auth,authpriv.*\E/, 'and which facilities are sent at all' );
};

subtest 'a guest that would ship to itself ships nowhere' => sub {

    # The natural way to turn this on for a fleet is one _base block, which
    # necessarily covers the collector as well -- and a collector forwarding to
    # its own listener is a loop.
    my ( $dir, $recipe, $vars ) = generated( host => $DOMAIN );

    is( conf($dir), q{}, 'nothing is configured' );

    my $fragment = $recipe->render(%$vars);
    unlike( $fragment, qr{/etc/rsyslog[.]d}, 'and the fragment installs nothing' );
    like( $fragment, qr/keeps its logs/, 'saying why rather than silently doing nothing' );
};

subtest 'naming the recipe without a destination fails the build' => sub {
    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'logshipper', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    # There is no "off": a guest that does not run this recipe already ships
    # nowhere.  So an unset host is a mistake, not a way of spelling disabled,
    # and it is worth stopping the build over rather than forwarding nothing.
    like(
        exception { $recipe->validate( domain => $DOMAIN ) },
        qr/host: Missing property/,
        'host is required, and the build stops naming the field that is absent'
    );
};

subtest 'nothing is required of anyone else' => sub {
    my ( undef, $recipe ) = generated();

    my %required = $recipe->required_recipes();
    is_deeply( [ sort keys %required ],    [], 'a sender needs no other recipe, and no firewall hole' );
    is_deeply( [ $recipe->rate_limits() ], [], 'because it listens on nothing' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
