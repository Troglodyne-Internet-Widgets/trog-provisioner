#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/skills-scratch-config.t - the provisioning-recipes scratch configuration: what
it copies, and what it changes on the way

=cut

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

require_ok("$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts/scratch_config")
  or BAIL_OUT('the scratch_config script does not load');

sub scratch {
    my (%opts) = @_;
    my $source = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$source/ipmap.cfg",    "[global]\nbasedir = /bogus\n" );
    File::Slurper::Temp::write_text( "$source/recipes.yaml", "_base:\n  _global:\n    distro: ubuntu\n    cpan_notest: 1\n  ntp: {}\nsome.test.test:\n  ntp: {}\n" );

    my $dir = tempdir( CLEANUP => 1 );
    Trog::Skill::ScratchConfig::build( $source, $dir, %opts );
    return YAML::XS::Load( File::Slurper::read_binary("$dir/recipes.yaml") );
}

subtest 'CPAN test suites are skipped, as on a real guest, unless asked for' => sub {

    # Most scratch builds check that a recipe installs at all, and a suite
    # failing in somebody else's distribution stops them before that part.
    my $recipes = scratch();
    is( $recipes->{_base}{_global}{cpan_notest}, 1, 'what the real configuration says is left alone' );

    # Asked for when what the build tests is what gets installed.
    $recipes = scratch( cpan_tests => 1 );
    ok( exists $recipes->{_base}{_global}{cpan_notest} && !$recipes->{_base}{_global}{cpan_notest}, 'and --cpan-tests turns the suites on' );
    is( $recipes->{_base}{_global}{distro}, 'ubuntu', 'leaving the rest of _global as it was' );
    is_deeply( [ sort keys %$recipes ], [qw{_base some.test.test}], 'and the rest of the file' );
};

done_testing();
