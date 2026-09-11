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

subtest 'a scratch build runs CPAN test suites, and keeps everything else _base said' => sub {
    my $source = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$source/ipmap.cfg",    "[global]\nbasedir = /bogus\n" );
    File::Slurper::Temp::write_text( "$source/recipes.yaml", "_base:\n  _global:\n    distro: ubuntu\n    cpan_notest: 1\n  ntp: {}\nsome.test.test:\n  ntp: {}\n" );

    my $dir = tempdir( CLEANUP => 1 );
    Trog::Skill::ScratchConfig::build( $source, $dir );

    my $recipes = YAML::XS::Load( File::Slurper::read_binary("$dir/recipes.yaml") );

    # Real guests skip them, for time; a failing suite is what a test build is
    # for finding.  Written over whatever the real configuration said.
    ok( exists $recipes->{_base}{_global}{cpan_notest} && !$recipes->{_base}{_global}{cpan_notest}, 'cpan_notest is off in _base _global' );

    is( $recipes->{_base}{_global}{distro}, 'ubuntu', 'and the rest of _global is as it was' );
    is_deeply( [ sort keys %$recipes ], [qw{_base some.test.test}], 'as is the rest of the file' );
};

done_testing();
