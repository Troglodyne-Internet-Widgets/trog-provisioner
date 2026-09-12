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

subtest 'host_of reads the host out of the forms a repo_url takes' => sub {
    is( Provisioner::Utils::host_of('https://github.com/o/r.git'),      'github.com', 'an https clone URL' );
    is( Provisioner::Utils::host_of('https://gitea.test:3000/api/v1/'), 'gitea.test', 'a port is not part of the host' );
    is( Provisioner::Utils::host_of('HTTPS://GitHub.COM/o/r'),          'github.com', 'and the case it was written in is not either' );

    # URI reads no host out of an scp-style address, and somebody will certainly
    # configure one: it is what gogs hands out.
    is( Provisioner::Utils::host_of('git@github.com:o/r.git'),       'github.com', 'an scp-style git address, which is not a URL' );
    is( Provisioner::Utils::host_of('ssh://git@gitea.test/o/r.git'), 'gitea.test', 'and an ssh one, which is' );

    is( Provisioner::Utils::host_of('not a url'), undef, 'something that names no host' );
    is( Provisioner::Utils::host_of(q{}),         undef, 'and nothing at all' );
    is( Provisioner::Utils::host_of(undef),       undef, 'without warning about it' );
};

done_testing;
