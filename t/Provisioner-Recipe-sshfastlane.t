#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-sshfastlane.t - what the sshfastlane recipe accepts, refuses and claims

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};

use FindBin::libs;

use Provisioner::Cookbook();

my $recipe = Provisioner::Cookbook->load( 'sshfastlane', distro => 'ubuntu' )->new(
    template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir    => '/nonexistent',
    distro        => 'ubuntu',
);

subtest 'the defaults' => sub {
    my %opts = $recipe->validate();
    is( $opts{port},         2222,         'the fast lane is on 2222' );
    is( $opts{max_startups}, '100:30:200', 'with a wide MaxStartups' );
    is( $opts{trust_days},   21,           'an address stays trusted for three weeks' );
    is( $opts{ipqos},        'ef none',    'and a shell is marked expedited, an rsync not at all' );
};

# The redirect sends 22 to the port.  On 22, the fast lane is the main sshd.
subtest 'what it refuses' => sub {
    like( exception { $recipe->validate( port         => 22 ) },      qr{/port},         'the port of the main sshd' );
    like( exception { $recipe->validate( trust_days   => 25 ) },      qr{/trust_days},   'a trust that ipset cannot time out' );
    like( exception { $recipe->validate( max_startups => '10:30' ) }, qr{/max_startups}, 'a MaxStartups that sshd cannot read' );
};

subtest 'it claims its port on every IPv4 address' => sub {
    is_deeply( [ $recipe->listens() ],               ['0.0.0.0:2222'], 'the default port, before validation' );
    is_deeply( [ $recipe->listens( port => 2200 ) ], ['0.0.0.0:2200'], 'or the port that it is given' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
