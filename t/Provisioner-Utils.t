#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Provisioner-Utils.t - the helpers more than one module leans on

=cut

use Test::More;
use Test::NoWarnings;

use FindBin::libs;

use_ok('Provisioner::Utils');

subtest 'fleet_address: what a name for another machine turns out to be' => sub {
    my %pool = ( ipmap => { 'cache.test.test' => '192.168.1.9' }, domain => 'guest.test.test' );
    my $ask  = sub { [ Provisioner::Utils::fleet_address( $_[0], %pool ) ] };

    is_deeply( $ask->(undef), [ none => q{} ], 'nothing named is no machine at all' );
    is_deeply( $ask->(q{}),   [ none => q{} ], 'and neither is an empty name' );

    # The scheme decides, not the dots: both of these are dotted.
    is_deeply( $ask->('http://cache.test.test:8080'), [ url => 'http://cache.test.test:8080' ], 'a URL is used exactly as written' );
    is_deeply( $ask->('HTTPS://Cache.test.test/'),    [ url => 'HTTPS://Cache.test.test/' ],    'whatever case its scheme is in' );

    is_deeply( $ask->('guest.test.test'), [ self    => q{} ],              'the guest asking about itself is told so' );
    is_deeply( $ask->('cache.test.test'), [ address => '192.168.1.9' ],    'a name the pool assigns resolves to its address' );
    is_deeply( $ask->('elsewhere.test'),  [ unknown => 'elsewhere.test' ], 'and one it does not comes back as the name' );

    # Self is checked before the pool, so a guest that is also in the pool --
    # which every guest is -- is still recognised as itself.
    my %own = ( ipmap => { 'guest.test.test' => '192.168.1.5' }, domain => 'guest.test.test' );
    is_deeply( [ Provisioner::Utils::fleet_address( 'guest.test.test', %own ) ], [ self => q{} ], 'even when the pool knows its address' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
