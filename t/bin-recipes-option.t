#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/bin-recipes-option.t - every script in bin/ that reads the file of --recipes
refuses a path that is not a file

=head1 DESCRIPTION

The option takes the path of a F<recipes.yaml>, not the name of a recipe.  See
L<Provisioner::Cookbook/"recipes_file($named)">.

Each script is loaded here as well as run, so that tests-covering chooses this
test when any of them changes.

=cut

use Test::More;
use IPC::Run3();
use File::Slurper();
use File::Temp qw{tempdir};

use FindBin;
use FindBin::libs;

# If a script falls through to its job, it finds no configuration to act on.
local $ENV{TROG_PROVISIONER_CONFIG} = tempdir( CLEANUP => 1 );

# bin/ipmap_to_globals writes the file that its --recipes names, so a file that
# is not there yet is one it creates.
my @scripts = grep { !m{/ipmap_to_globals\z} && File::Slurper::read_text($_) =~ m/\x27recipes=s\x27/ } sort glob "$FindBin::Bin/../bin/*";
cmp_ok( scalar @scripts, '>=', 6, 'the scripts that take --recipes are found' ) or diag "found: @scripts";

foreach my $script (@scripts) {
    my ($name) = $script =~ m{([^/]+)\z};

    subtest $name => sub {
        require_ok($script);

        my $said = q{};
        IPC::Run3::run3( [ $^X, $script, qw{--recipes /bogus/nosuch.yaml test.test} ], \undef, \$said, \$said );
        isnt( $?, 0, 'a --recipes that is not a file exits non-zero' );
        like( $said, qr{'/bogus/nosuch[.]yaml'[ ]is[ ]not[ ]a[ ]file}, 'naming the path' );
    };
}

done_testing;
