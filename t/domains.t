#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/domains.t - bin/domains prints each domain of the configuration

=cut

use Test::More;
use Capture::Tiny qw{capture};
use File::Path    qw{make_path};
use File::Slurper::Temp();
use File::Temp qw{tempdir};

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../bin/domains";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $dir = tempdir( CLEANUP => 1 );
make_path("$dir/recipes.d");
File::Slurper::Temp::write_text( "$dir/recipes.yaml",                "_base: {}\n_shared: {}\nzulu.test: {}\n" );
File::Slurper::Temp::write_text( "$dir/recipes.d/alpha.test.yaml",   "alpha.test: {}\n" );
File::Slurper::Temp::write_text( "$dir/recipes.d/old.test.yaml.bak", "old.test: {}\n" );

my $other = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$other/recipes.yaml", "other.test: {}\n" );

subtest 'the configuration of the installation' => sub {
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;
    my ( $out, $err, $rc ) = capture { Trog::Bin::Domains::main() };
    is( $rc,  0,                         'it exits 0' ) or diag $err;
    is( $out, "alpha.test\nzulu.test\n", 'each domain of recipes.yaml and recipes.d, sorted, with no section and no backup file' );
};

subtest 'another configuration, through --recipes' => sub {
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;
    my ( $out, $err, $rc ) = capture { Trog::Bin::Domains::main( '--recipes', "$other/recipes.yaml" ) };
    is( $rc,  0,              'it exits 0' ) or diag $err;
    is( $out, "other.test\n", 'the domains of that file, not of the installation' );
};

done_testing();
