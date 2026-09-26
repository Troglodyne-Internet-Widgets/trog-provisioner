#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/new_config-order.t - order_only and targets_in_order in bin/new_config:
which targets must finish before which, and the slot of each

=cut

use FindBin;
use FindBin::libs;
use Test::More;
use Test::NoWarnings qw{had_no_warnings};

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

my $S = '/etc/provisioner/state/o.test.test';
my $G = '/etc/provisioner/state';

# tcms requires perl and nginxproxy, and nginxproxy requires nginx, which has a
# global target and one per domain.  ufw is required too, and has its place in
# targets_in_order rather than here.
my %targets_of = (
    tcms       => ["$S/tcms"],
    nginxproxy => ["$S/nginxproxy"],
    nginx      => [ "$G/global_nginx", "$S/nginx" ],
    perl       => ["$S/perl"],
    ufw        => ["$S/ufw"],
    cron       => ["$G/global_cron"],
);
my %required_by = ( perl => ['tcms'], nginxproxy => ['tcms'], nginx => ['nginxproxy'], ufw => [qw{nginx tcms}] );
my @ordered     = ( "$G/global_cron", "$S/tcms", "$S/nginxproxy", "$G/global_nginx", "$S/nginx", "$S/perl" );

subtest 'order_only' => sub {
    my %before = Trog::Provisioner::Config::Generator::order_only( [qw{cron tcms nginxproxy nginx perl ufw}], \%targets_of, \%required_by, \@ordered );

    is_deeply( $before{"$S/perl"},         ["$S/tcms"],         'a dependency waits for the recipe that required it' );
    is_deeply( $before{"$S/nginxproxy"},   ["$S/tcms"],         'each dependency does' );
    is_deeply( $before{"$G/global_nginx"}, ["$S/nginxproxy"],   'and its first target is the one that waits' );
    is_deeply( $before{"$S/nginx"},        ["$G/global_nginx"], 'a recipe runs its global target before its own' );
    ok( !exists $before{"$G/global_cron"}, 'a recipe that nothing required waits for no other recipe' );
    ok( !exists $before{"$S/ufw"},         'and ufw is left to targets_in_order' );
};

subtest 'targets_in_order' => sub {
    my %before = Trog::Provisioner::Config::Generator::order_only( [qw{cron tcms nginxproxy nginx perl ufw}], \%targets_of, \%required_by, \@ordered );
    my %args   = ( state_dir => $S, user => 'svc', admin_user => 'admin', modules => \@ordered, order_only => \%before );

    my @all    = Trog::Provisioner::Config::Generator::targets_in_order( %args, fetch => 1, ufw => 1 );
    my %at     = map { $_->{target} => $_ } @all;
    my @global = map { "$S/$_" } qw{state service_user sysctl packages scripts data ssl ssh sendmail testdeps};

    is_deeply( [ map { $_->{target} } @all ],    [ @global, "$S/fetch_via_cache", @ordered, "$S/ufw" ], 'the global targets, the cache, the recipes in order, and ufw last' );
    is_deeply( [ map { $_->{slot} } @all ],      [ 1 .. scalar @all ],                                  'each in the slot of its place, from 1' );
    is_deeply( $at{"$S/state"}{after},           [],                                                    'the first waits for nothing' );
    is_deeply( $at{"$S/sysctl"}{after},          ["$S/service_user"],                                   'each global target waits for the one before it' );
    is_deeply( $at{"$S/fetch_via_cache"}{after}, ["$S/testdeps"],                                       'the cache for the last of them' );
    is_deeply( $at{"$S/perl"}{after},            [ "$S/fetch_via_cache", "$S/tcms" ],                   'a recipe for the cache and for what order_only says' );
    is_deeply( $at{"$S/ufw"}{after},             [ "$S/fetch_via_cache", @ordered ],                    'and ufw for every recipe' );

    my @plain = Trog::Provisioner::Config::Generator::targets_in_order( %args, fetch => 0, ufw => 0 );
    is_deeply( +{ map { $_->{target} => $_->{after} } @plain }->{"$G/global_cron"}, ["$S/testdeps"], 'without a cache, a recipe waits for the last global target' );
    ok( !grep( { $_->{target} =~ m{/(?:ufw|fetch_via_cache)\z} } @plain ), 'and neither ufw nor the cache is there unless asked for' );

    my @as_admin = Trog::Provisioner::Config::Generator::targets_in_order( %args, user => 'admin' );
    is( $as_admin[1]{target}, "$S/admin_user", 'a domain run as its admin makes the admin account' );
    my @nobody = Trog::Provisioner::Config::Generator::targets_in_order( %args, user => undef );
    is( $nobody[1]{target}, "$S/sysctl", 'and a domain with no user makes neither' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
