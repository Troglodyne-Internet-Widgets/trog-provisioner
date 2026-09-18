#!/usr/bin/perl

use 5.014;

use strict;
use warnings FATAL => 'all';

# The first argument is the directory that holds the repositories.  The rest is
# the command that installs the dependencies of one directory, which gets the
# directory appended.  admincode passes cpan_install's installdeps.
my ( $REPO_BASEDIR, @INSTALLDEPS ) = @ARGV;

die "Must pass repo basedir as first arg"                                     unless $REPO_BASEDIR;
die "Must pass the command that installs a directory's dependencies after it" unless @INSTALLDEPS;

# One level only, so glob is enough, and * skips the dot entries.
my @subdirs = grep { -d $_ } glob("$REPO_BASEDIR/*");

my $had_failures = 0;
foreach my $repo_dir (@subdirs) {

    # TODO: install the dependencies of dzil and Module::Build distributions (#225).
    next unless -f "$repo_dir/Makefile.PL";    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- which build system the repo has, not an access check

    # All of $?, so that a child killed by a signal counts as a failure.
    system( @INSTALLDEPS, "$repo_dir/" );
    if ($?) {
        $had_failures++;
        next;
    }

    if ( -d "$repo_dir/t" ) {
        system( qw{prove -vm}, "$repo_dir/t" );
        $had_failures++ if $?;
    }
}

# Every repository is tried, and the exit code says whether any failed.
exit( $had_failures ? 1 : 0 );
