#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/recipes-remotetests.t - every recipe has guest tests, and a test that
generates it

=head1 DESCRIPTION

Each recipe has F<t/remotetests-$recipe.t>, which generates its domain and
checks its guest tests under C<AUTHOR_TESTING>.  One file for each recipe, so
that the pre-commit hook runs only the one for the recipe that changed.  See
L<Trog::Test::RemoteTests>.  This test is the index of them, and runs without
C<AUTHOR_TESTING>.

=cut

use FindBin;
use FindBin::libs;
use File::Temp();
use Test::More;

use Trog::Test::RemoteTests();

my @recipes = Trog::Test::RemoteTests::recipes();
ok( scalar @recipes, 'there are recipes to test' );

subtest 'every recipe has guest tests' => sub {
    my $scratch = File::Temp::tempdir( CLEANUP => 1 );
    foreach my $recipe (@recipes) {
        my $class = "Provisioner::Recipe::$recipe";
        require_ok($class) or next;
        ok( scalar $class->new( output_dir => $scratch )->tests(), "$recipe has guest tests" );
    }
};

subtest 'every recipe has its own test, which runs that recipe' => sub {
    foreach my $recipe (@recipes) {
        my $file   = "$FindBin::Bin/remotetests-$recipe.t";
        my $source = eval { local ( @ARGV, $/ ) = ($file); <> } // q{};
        like( $source, qr{Trog::Test::RemoteTests::run\(\s*q\{\Q$recipe\E\}\s*\)}, "t/remotetests-$recipe.t runs $recipe" );
    }
};

subtest 'and there is no test for a recipe that is gone' => sub {
    my %known = map  { $_ => 1 } @recipes;
    my @stray = grep { !$known{$_} } map { m{/remotetests-(.+)[.]t\z} ? $1 : () } glob "$FindBin::Bin/remotetests-*.t";
    is( "@stray", '', 'each one is for a recipe that exists' );
};

done_testing();
