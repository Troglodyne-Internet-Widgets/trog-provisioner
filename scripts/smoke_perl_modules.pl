#!/usr/bin/env perl

use strict;
use warnings;

use File::Basename qw{basename};

my $REPO_BASEDIR = $ARGV[0];
my $CPANM_PATH   = $ARGV[1];

die "Must pass repo basedir as first arg" unless $REPO_BASEDIR;
die "Must pass path to cpanm to use as second arg" unless $CPANM_PATH;

opendir(my $dh, $REPO_BASEDIR);
my @subdirs = grep { -d "$REPO_BASEDIR/$_" && !m/^\.+$/ } readdir($dh);
close $dh;

my $had_failures=0;
foreach my $REPO_DIR (@subdirs) {
    my $repo_dirname = basename($REPO_DIR);
    $repo_dirname = "$REPO_BASEDIR/$repo_dirname";

    next unless -d "$repo_dirname/";

    # TODO understand deps for dzil/MB
    next unless -f "$repo_dirname/Makefile.PL";
    system($CPANM_PATH, '--installdeps', "$repo_dirname/");
    my $rc = $? >> 8;
    if( $rc) {
        $had_failures++;
        next;
    }

    if (-d "$repo_dirname/t") {
        system(qw{prove -vm}, "$repo_dirname/t");
        $rc = $? >> 8;
        $had_failures++ if $rc;
    }
}
