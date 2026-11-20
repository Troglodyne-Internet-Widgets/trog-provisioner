#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-grafanaossec.t - the dashboards of the OSSEC alerts plug
into the manager, and claim the port where the alerts arrive

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};

use FindBin::libs;

use_ok('Provisioner::Recipe::grafanaossec') or BAIL_OUT('Provisioner::Recipe::grafanaossec does not load');

my $recipe = 'Provisioner::Recipe::grafanaossec'->new( output_dir => '/bogus', libdir => '.', target_packager => 'deb' );

subtest 'required_recipes' => sub {
    my %required = $recipe->required_recipes();
    is_deeply( [ sort keys %required ],  [qw{grafanasyslog ossec}], 'it needs the manager whose alerts it draws, and grafanasyslog, which installs telegraf and grafana' );
    is_deeply( { $required{ossec}->() }, {},                        'and asks the manager for nothing, because it plugs in through a fragment of ossec.conf.d' );
};

subtest 'listens' => sub {
    is_deeply( [ $recipe->listens() ],                       ['127.0.0.1:10516/udp'], 'telegraf reads the alerts on loopback' );
    is_deeply( [ $recipe->listens( alerts_port => 20516 ) ], ['127.0.0.1:20516/udp'], 'on the port that the configuration names' );
};

subtest 'args' => sub {
    my %opts = $recipe->validate( domain => 'logs.test.test' );
    is( $opts{alerts_port}, 10516, 'the default port of the alerts is the one that listens assumes' );
};

had_no_warnings();
done_testing();
