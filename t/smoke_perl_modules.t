#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/smoke_perl_modules.t - scripts/smoke_perl_modules.pl: every repository is smoked, and the exit code says whether any failed

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/smoke_perl_modules.pl";

# A repository with a Makefile.PL and one test, which passes or fails.
sub repo {
    my ( $base, $name, $passes ) = @_;

    make_path("$base/$name/t");
    File::Slurper::Temp::write_text( "$base/$name/Makefile.PL", "# bogus\n" );
    File::Slurper::Temp::write_text( "$base/$name/t/smoke.t",   $passes ? "print qq{1..1\\nok 1\\n};\n" : "print qq{1..1\\nnot ok 1\\n};\n" );
    return;
}

sub smoke {
    my ( $base, @installdeps ) = @_;

    IPC::Run3::run3( [ $^X, $script, $base, @installdeps ], \undef, \my $out, \my $err );
    return $?;
}

subtest 'every suite passes' => sub {
    my $base = tempdir( CLEANUP => 1 );
    repo( $base, 'bogus-good', 1 );
    is( smoke( $base, 'true' ), 0, 'it exits 0' );
};

subtest 'a suite fails' => sub {
    my $base = tempdir( CLEANUP => 1 );
    repo( $base, 'bogus-good', 1 );
    repo( $base, 'bogus-bad',  0 );
    isnt( smoke( $base, 'true' ), 0, 'it exits non-zero' );
};

subtest 'dependencies fail to install' => sub {
    my $base = tempdir( CLEANUP => 1 );
    repo( $base, 'bogus-good', 1 );
    isnt( smoke( $base, 'false' ), 0, 'it exits non-zero' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
