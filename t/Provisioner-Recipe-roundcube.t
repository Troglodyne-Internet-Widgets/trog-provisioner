#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-roundcube.t - webmail goes through the relay of nginx when
the domain has one

=cut

use Test::More;
use Test::NoWarnings;
use Test::MockModule();

use FindBin::libs;

use Provisioner::Cookbook();

# What roundcube asks of nginx on webmail.test.test, configured as %config.
sub asked_of_nginx {
    my (%config) = @_;

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( configuration => sub { return { 'webmail.test.test' => {%config} } } );

    my %required = Provisioner::Cookbook->load('roundcube')->required_recipes( domain => 'webmail.test.test' );
    return { $required{nginx}->() };
}

subtest 'with a relay, webmail is a public name, and its jail bans through the relay' => sub {
    my $asked = asked_of_nginx( nginx => { relay => 'relay.test.test' }, roundcube => { version => '1.6.9' } );
    is_deeply( $asked->{sites},         ['webmail.webmail.test.test'],                                  'the vhost of webmail' );
    is_deeply( $asked->{public_names},  { 'webmail.webmail.test.test' => 'webmail.webmail.test.test' }, 'is the name that the relay sends to it' );
    is_deeply( $asked->{proxied_jails}, ['roundcube-auth'],                                             'and the jail that reads its failed logins bans through the relay' );
};

subtest 'without a relay, webmail is only a vhost of the guest' => sub {
    foreach my $case ( [ 'nginx without a relay' => { nginx => {} } ], [ 'no nginx block' => {} ] ) {
        my ( $what, $config ) = @$case;
        my $asked = asked_of_nginx(%$config);
        is_deeply( [ sort keys %$asked ], ['sites'], "$what: roundcube asks nginx for the vhost alone" );
    }
};

Test::NoWarnings::had_no_warnings();

done_testing;
