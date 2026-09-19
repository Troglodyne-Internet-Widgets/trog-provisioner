#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/smoke_perl_modules.t - scripts/smoke_perl_modules.pl: each checkout gets the
installer that its build system needs, then its tests, and the exit code says
whether any failed

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper();
use File::Slurper::Temp();
use List::Util qw{any};
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/smoke_perl_modules.pl";

# A checkout with the files named, and a t/ unless told otherwise.
sub checkout {
    my ( $base, $name, @files ) = @_;

    make_path("$base/$name");
    make_path("$base/$name/t") unless any { $_ eq 'no-t' } @files;
    File::Slurper::Temp::write_text( "$base/$name/$_", "# bogus\n" ) for grep { $_ ne 'no-t' } @files;
    return;
}

# Runs the script against a stand-in for cpan_install, which writes each call
# to a log and fails the verbs in $fails.  Returns the exit code, and each call
# as a list of its words, with the base directory taken off, in the order made.
sub smoke {
    my ( $base, %opts ) = @_;

    my $bin = tempdir( CLEANUP => 1 );
    my $log = "$bin/calls";
    File::Slurper::Temp::write_text( "$bin/cpan_install", <<"FAKE" );
#!$^X
open( my \$fh, '>>', '$log' ) or die \$!;
print {\$fh} "\@ARGV\\n";
close(\$fh) or die \$!;
exit( grep( { \$_ eq \$ARGV[-2] } split( ' ', \$ENV{SMOKE_FAILS} // '' ) ) ? 1 : 0 );
FAKE
    chmod 0755, "$bin/cpan_install" or die "Cannot make the stand-in executable: $!";

    local $ENV{SMOKE_FAILS} = $opts{fails} // '';
    IPC::Run3::run3( [ $^X, $script, $base, "$bin/cpan_install", @{ $opts{flags} // [] } ], \undef, \my $out, \my $err );
    my $rc = $?;

    my @calls = -e $log ? map { [ split ' ', s{\Q$base\E/}{}r ] } split /\n/, File::Slurper::read_text($log) : ();
    return ( $rc, @calls );
}

subtest 'each checkout gets the installer that its build system needs' => sub {
    my $base = tempdir( CLEANUP => 1 );
    checkout( $base, qw{a-dzil dist.ini Makefile.PL} );
    checkout( $base, qw{b-eumm Makefile.PL} );
    checkout( $base, qw{c-mb Build.PL} );
    checkout( $base, qw{d-none README} );
    checkout( $base, qw{e-untested Makefile.PL no-t} );

    my ( $rc, @calls ) = smoke( $base, flags => ['--notest'] );
    is( $rc, 0, 'it exits 0' );
    is_deeply(
        \@calls,
        [
            [qw{--notest dzil a-dzil}],
            [qw{test a-dzil}],
            [qw{--notest installdeps b-eumm}],
            [qw{test b-eumm}],
            [qw{--notest installdeps c-mb}],
            [qw{test c-mb}],
            [qw{--notest installdeps e-untested}],
        ],
        'dist.ini before Makefile.PL, Build.PL as Makefile.PL, the flags before the verb, no tests without t/, and nothing for a checkout with no build system'
    );
};

subtest 'a suite fails' => sub {
    my $base = tempdir( CLEANUP => 1 );
    checkout( $base, qw{a-good Makefile.PL} );
    checkout( $base, qw{b-good Makefile.PL} );

    my ( $rc, @calls ) = smoke( $base, fails => 'test' );
    isnt( $rc, 0, 'it exits non-zero' );
    is( scalar( grep { $_->[0] eq 'test' } @calls ), 2, 'and still tests every checkout' );
};

subtest 'dependencies fail to install' => sub {
    my $base = tempdir( CLEANUP => 1 );
    checkout( $base, qw{a-dzil dist.ini} );

    my ( $rc, @calls ) = smoke( $base, fails => 'dzil' );
    isnt( $rc, 0, 'it exits non-zero' );
    is_deeply( \@calls, [ [qw{dzil a-dzil}] ], 'and does not test what it could not install for' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
