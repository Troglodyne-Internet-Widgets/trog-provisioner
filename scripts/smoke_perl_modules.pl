#!/usr/bin/perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use File::Basename qw{basename};

# The first argument is the directory that holds the repositories.  The rest is
# the command that installs the dependencies of one directory, which gets the
# directory appended.  admincode passes cpan_install's installdeps.
my ( $REPO_BASEDIR, @INSTALLDEPS ) = @ARGV;

die "Must pass repo basedir as first arg"                                     unless $REPO_BASEDIR;
die "Must pass the command that installs a directory's dependencies after it" unless @INSTALLDEPS;

# One level only, so glob is enough, and * skips the dot entries.
my @subdirs = grep { -d $_ } glob("$REPO_BASEDIR/*");

my $had_failures = 0;
foreach my $REPO_DIR (@subdirs) {
    my $repo_dirname = basename($REPO_DIR);
    $repo_dirname = "$REPO_BASEDIR/$repo_dirname";

    next unless -d "$repo_dirname/";

    # TODO: install the dependencies of dzil and Module::Build distributions (#225).
    next unless -f "$repo_dirname/Makefile.PL";    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- which build system the repo has, not an access check
    system( @INSTALLDEPS, "$repo_dirname/" );
    my $rc = $? >> 8;
    if ($rc) {
        $had_failures++;
        next;
    }

    if ( -d "$repo_dirname/t" ) {
        system( qw{prove -vm}, "$repo_dirname/t" );
        $rc = $? >> 8;
        $had_failures++ if $rc;
    }
}
