#!/usr/bin/perl

use 5.014;

use strict;
use warnings FATAL => 'all';

# Installs the dependencies of each checkout in a directory, then runs its tests.
#
#     smoke_perl_modules.pl BASEDIR CPAN_INSTALL [FLAG ...]
#
# CPAN_INSTALL is the path of scripts/cpan_install, and each FLAG goes to it
# before the verb, such as --notest.  admincode passes its basedir.
my ( $REPO_BASEDIR, $CPAN_INSTALL, @FLAGS ) = @ARGV;

die "Must pass repo basedir as first arg"         unless $REPO_BASEDIR;
die "Must pass the path of cpan_install after it" unless $CPAN_INSTALL;

# One level only, so glob is enough, and * skips the dot entries.
my @subdirs = grep { -d $_ } glob("$REPO_BASEDIR/*");

## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- which build system the checkout has, not an access check
my $had_failures = 0;
foreach my $repo_dir (@subdirs) {

    # dist.ini first: a Dist::Zilla checkout can also carry a Makefile.PL that
    # it generated, and only dzil knows the author dependencies.  cpanm reads a
    # Build.PL as it reads a Makefile.PL.
    my $verb =
        -f "$repo_dir/dist.ini"                                   ? 'dzil'
      : ( -f "$repo_dir/Makefile.PL" || -f "$repo_dir/Build.PL" ) ? 'installdeps'
      :                                                             undef;
    next unless $verb;

    # All of $?, so that a child killed by a signal counts as a failure.
    system( $CPAN_INSTALL, @FLAGS, $verb, $repo_dir );
    if ($?) {
        $had_failures++;
        next;
    }

    if ( -d "$repo_dir/t" ) {
        system( $CPAN_INSTALL, 'test', $repo_dir );
        $had_failures++ if $?;
    }
}
## use critic

# Every repository is tried, and the exit code says whether any failed.
exit( $had_failures ? 1 : 0 );
