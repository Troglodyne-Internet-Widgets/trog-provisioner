#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/qualify_site_data.t - where bin/qualify_site_data looks when it is not told

=head1 DESCRIPTION

Both files it rewrites default to the configuration directory, as every other
program here does, and not to the directory it happens to run from.

=cut

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use FindBin;
use FindBin::libs;
use Test::More;
use Capture::Tiny qw{capture_stdout};
use File::Path    qw{make_path};
use File::Slurper::Temp();

require_ok("$FindBin::Bin/../bin/qualify_site_data") or BAIL_OUT('bin/qualify_site_data does not load');

my $conf = $ENV{TROG_PROVISIONER_CONFIG};
make_path("$conf/recipes.d");
File::Slurper::Temp::write_text( "$conf/recipes.d/short.yaml", "short:\n    nosnap:\n" );

# A working directory with no recipes.d in it, so a default relative to it finds
# nothing to qualify.
my $elsewhere = File::Temp::tempdir( CLEANUP => 1 );
chdir $elsewhere or die "Cannot chdir to $elsewhere: $!";

my ($said) = capture_stdout { Trog::Bin::QualifySiteData::main(qw{--tld test.test --dryrun}) };
ok( index( $said, "$conf/recipes.d/short.yaml: short -> short.test.test" ) >= 0, 'recipes.d is read out of the configuration directory' ) or diag $said;

done_testing();
