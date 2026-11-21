#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-cron.t - the cron recipe knows where OSSEC does the jobs
of its log watchers

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::MockModule();

use FindBin::libs;

use_ok('Provisioner::Recipe::cron')         or BAIL_OUT('Provisioner::Recipe::cron does not load');
use_ok('Provisioner::Recipe::Ubuntu::cron') or BAIL_OUT('Provisioner::Recipe::Ubuntu::cron does not load');
require Provisioner::Recipe::ossec;

my $recipe = 'Provisioner::Recipe::cron'->new( output_dir => '/bogus', libdir => '.', target_packager => 'deb' );

subtest 'enrich' => sub {
    my $ossec = Test::MockModule->new('Provisioner::Recipe::ossec');
    my %asked;
    my $answer;
    $ossec->redefine( watches => sub { my ( undef, $domain ) = @_; $asked{$domain}++; return $answer } );

    my %base = ( domain => 'guest.test.test', admin_email => 'admin@test.test', modules => [] );

    $answer = 1;
    my %opts = $recipe->enrich(%base);
    is( $opts{ossec_watches}, 1, 'the watchers that OSSEC replaces stop where its manager watches the guest' );
    is_deeply( \%asked, { 'guest.test.test' => 1 }, 'and the recipe asks about this domain' );

    $answer = 0;
    %opts   = $recipe->enrich(%base);
    is( $opts{ossec_watches}, 0, 'and run where it does not' );
};

subtest 'deps' => sub {
    my $ubuntu = 'Provisioner::Recipe::Ubuntu::cron'->new( output_dir => '/bogus', libdir => '.', target_packager => 'deb' );
    my $ossec  = Test::MockModule->new('Provisioner::Recipe::ossec');
    my %asked;
    my $answer;
    $ossec->redefine( watches => sub { my ( undef, $domain ) = @_; $asked{$domain}++; return $answer } );

    $answer = 1;
    is_deeply( [ sort $ubuntu->deps( domain => 'guest.test.test' ) ], [qw{cronie debsums sysstat}], 'where OSSEC watches the guest, its agent runs rootcheck, so the guest gets no rkhunter' );
    is_deeply( \%asked,                                               { 'guest.test.test' => 1 },   'and the recipe asks about this domain' );

    $answer = 0;
    is_deeply( [ sort $ubuntu->deps( domain => 'guest.test.test' ) ], [qw{cronie debsums rkhunter sysstat}], 'and where it does not, the guest gets rkhunter' );

    %asked = ();
    is_deeply( [ sort $ubuntu->deps() ], [qw{cronie debsums rkhunter sysstat}], 'and so does a caller that names no domain' );
    is_deeply( \%asked,                  {},                                    'without a question about a domain that it did not name' );
};

had_no_warnings();
done_testing();
