#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-ossec.t - the ossec recipe asks the collector for the
stream on the port where the manager reads it, and claims both of its ports

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};

use FindBin::libs;

use_ok('Provisioner::Recipe::ossec') or BAIL_OUT('Provisioner::Recipe::ossec does not load');

my $recipe = 'Provisioner::Recipe::ossec'->new( output_dir => '/bogus', libdir => '.', target_packager => 'deb' );

subtest 'required_recipes' => sub {
    my %required = $recipe->required_recipes();
    ok( exists $required{grafanasyslog}, 'it needs grafanasyslog, which installs telegraf and grafana' );
    is_deeply( { $required{logcollector}->() }, { forward_text => ['127.0.0.1:10514'] }, 'and asks the collector for a copy as text on the default port' );

    my %moved = $recipe->required_recipes( port => 20514 );
    is_deeply( { $moved{logcollector}->() }, { forward_text => ['127.0.0.1:20514'] }, 'and on the port that the configuration names' );
};

subtest 'listens' => sub {
    is_deeply( [ $recipe->listens() ],                                      [qw{127.0.0.1:10514 127.0.0.1:10516/udp}], 'the manager on TCP and telegraf on UDP, both on loopback' );
    is_deeply( [ $recipe->listens( port => 20514, alerts_port => 20516 ) ], [qw{127.0.0.1:20514 127.0.0.1:20516/udp}], 'on the ports that the configuration names' );
};

subtest 'args' => sub {
    my %opts = $recipe->validate();
    is( $opts{port},        10514, 'the default port of the manager is the one that required_recipes and listens assume' );
    is( $opts{alerts_port}, 10516, 'and so is the default port of the alerts' );
};

had_no_warnings();
done_testing();
