#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/skills-clean-scratch.t - clean_scratch: every scratch configuration under a directory, and each of its domains

=cut

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Path       qw{make_path};
use File::Temp       qw{tempdir};
use File::Slurper::Temp();

use FindBin;
use FindBin::libs;

require_ok("$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts/clean_scratch")
  or BAIL_OUT('the clean_scratch script does not load');

# A scratch configuration at $dir: the marker, and a file in recipes.d for each
# domain.
sub scratch_config {
    my ( $dir, @domains ) = @_;
    make_path("$dir/recipes.d");
    no warnings 'once';
    File::Slurper::Temp::write_text( "$dir/$Trog::Skill::CleanScratch::MARKER", "Built by scratch_config; safe to remove.\n" );
    for my $domain (@domains) { File::Slurper::Temp::write_text( "$dir/recipes.d/$domain.yaml", "---\n" ); }
    return;
}

# One run of main over $under, with the scripts that it runs stood in for: what
# it ran, and what it returned.  %fails names an argument list, joined by
# spaces, that exits 1.
sub clean {
    my ( $under, %fails ) = @_;
    my @ran;
    my $script = Test::MockModule->new( 'Trog::Skill::CleanScratch', no_auto => 1 );
    $script->redefine( run_script => sub { push @ran, "@_"; return $fails{"@_"} ? 1 : 0 } );
    my $rc = Trog::Skill::CleanScratch::main($under);
    return ( $rc, @ran );
}

subtest 'each domain of each scratch configuration' => sub {
    my $under = tempdir( CLEANUP => 1 );
    scratch_config( "$under/trog-scratch-one",        qw{b.test a.test} );
    scratch_config( "$under/deeper/trog-scratch-two", qw{c.test} );
    scratch_config("$under/trog-scratch-empty");

    # The data source of a scratch configuration is inside it, and a guest of
    # it can carry a directory with the marker.
    scratch_config( "$under/trog-scratch-one/data/a.test", qw{inner.test} );

    my ( $rc, @ran ) = clean($under);
    is( $rc, 0, 'nothing failed, so it exits 0' );
    is_deeply(
        \@ran,
        [
            "teardown --config $under/deeper/trog-scratch-two c.test",
            "scratch_config --remove $under/trog-scratch-empty",
            "teardown --config $under/trog-scratch-one a.test",
            "teardown --config $under/trog-scratch-one b.test",
        ],
        'it tears down each domain, removes a configuration with none, and does not look inside a configuration that it found'
    );
};

subtest 'a teardown that fails' => sub {
    my $under = tempdir( CLEANUP => 1 );
    scratch_config( "$under/trog-scratch-one", qw{a.test b.test} );
    my ( $rc, @ran ) = clean( $under, "teardown --config $under/trog-scratch-one a.test" => 1 );
    is( $rc,         1, 'one failure makes it exit 1' );
    is( scalar @ran, 2, 'after it tried the other domains too' );
};

subtest 'a directory with nothing in it' => sub {
    my $under = tempdir( CLEANUP => 1 );
    make_path("$under/output");
    my ( $rc, @ran ) = clean($under);
    is( $rc,         0, 'a run that made no scratch configuration exits 0' );
    is( scalar @ran, 0, 'and runs nothing' );

    like( exception { Trog::Skill::CleanScratch::main("$under/bogus") }, qr/is\ not\ a\ directory/, 'a directory that is not there dies' );
};

done_testing;
