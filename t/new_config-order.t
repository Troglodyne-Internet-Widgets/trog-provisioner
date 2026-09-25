#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/new_config-order.t - order_only in bin/new_config: which recipe targets must
finish before which

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
# templates/makefile.tt rather than here.
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

my %edges = Trog::Provisioner::Config::Generator::order_only( [qw{cron tcms nginxproxy nginx perl ufw}], \%targets_of, \%required_by, \@ordered );

is_deeply( $edges{"$S/perl"},         ["$S/tcms"],         'a dependency waits for the recipe that required it' );
is_deeply( $edges{"$S/nginxproxy"},   ["$S/tcms"],         'each dependency does' );
is_deeply( $edges{"$G/global_nginx"}, ["$S/nginxproxy"],   'and its first target is the one that waits' );
is_deeply( $edges{"$S/nginx"},        ["$G/global_nginx"], 'a recipe runs its global target before its own' );
ok( !exists $edges{"$G/global_cron"}, 'a recipe that nothing required waits for no other recipe' );
ok( !exists $edges{"$S/ufw"},         'and ufw is left to the template' );

Test::NoWarnings::had_no_warnings();
done_testing();
