#!/usr/bin/env perl

use strict;
use warnings;

use File::Basename qw{basename};

# The command that installs a distribution's dependencies, with the directory
# to be appended: cpan_install's installdeps, as admincode queues it, so that
# this goes through the fetch cache like everything else.
my ( $REPO_BASEDIR, @INSTALLDEPS ) = @ARGV;

die "Must pass repo basedir as first arg"                                     unless $REPO_BASEDIR;
die "Must pass the command that installs a directory's dependencies after it" unless @INSTALLDEPS;

opendir( my $dh, $REPO_BASEDIR );
my @subdirs = grep { -d "$REPO_BASEDIR/$_" && !m/^\.+$/ } readdir($dh);
close $dh;

my $had_failures = 0;
foreach my $REPO_DIR (@subdirs) {
    my $repo_dirname = basename($REPO_DIR);
    $repo_dirname = "$REPO_BASEDIR/$repo_dirname";

    next unless -d "$repo_dirname/";

    # TODO understand deps for dzil/MB
    next unless -f "$repo_dirname/Makefile.PL";
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
