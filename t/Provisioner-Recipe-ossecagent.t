#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-ossecagent.t - the agent sends to the address of its
manager, and holds the key that its manager issues

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::Fatal      qw{exception};

use FindBin::libs;

use_ok('Provisioner::Recipe::ossecagent') or BAIL_OUT('Provisioner::Recipe::ossecagent does not load');

my $recipe = 'Provisioner::Recipe::ossecagent'->new( output_dir => '/bogus', libdir => '.', target_packager => 'deb' );

subtest 'enrich' => sub {
    my %base = ( domain => 'guest.test.test', manager => 'logs.test.test', ipmap => { 'logs.test.test' => '192.0.2.9' } );

    my %opts = $recipe->enrich(%base);
    is( $opts{manager_ip}, '192.0.2.9', 'the agent sends to the address that the pool assigns the manager' );

    %opts = $recipe->enrich( %base, ipmap => {} );
    is( $opts{manager_ip}, q{}, 'and none when the pool assigns it none, so the guest looks up the name' );

    my $err = exception { $recipe->enrich( %base, manager => 'https://logs.test.test' ) };
    like( $err, qr/is[ ]a[ ]URL/, 'and the build stops on a URL, which names no host to send to' );
};

subtest 'grants' => sub {
    is_deeply(
        [ $recipe->grants( 'guest.test.test', manager => 'logs.test.test' ) ],
        [ { recipe => 'ossec', guest => 'logs.test.test', client => 'guest.test.test' } ],
        'the ossec recipe of the manager issues the key of the agent of this guest'
    );
    is_deeply( [ $recipe->grants('guest.test.test') ], [], 'and no manager issues nothing' );
};

subtest 'required_recipes' => sub {
    my %required = $recipe->required_recipes();
    is_deeply( { $required{configd}->() }, { languages => ['ossec'] }, 'configd makes ossec.conf, as on the manager' );
};

had_no_warnings();
done_testing();
