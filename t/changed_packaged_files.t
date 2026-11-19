#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/changed_packaged_files.t - scripts/changed_packaged_files: report each file
of a package that changed since the last run, once, unless a recipe expects it

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::MockModule;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper::Temp();
use Capture::Tiny qw{capture};

use FindBin;

my $script = "$FindBin::Bin/../scripts/changed_packaged_files";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $dir = tempdir( CLEANUP => 1 );
mkdir "$dir/expected" or die "Cannot make $dir/expected: $!";
File::Slurper::Temp::write_text( "$dir/dpkg.status", '' );

# The script loads at run time, so the compiler sees each of these once.
no warnings qw{once};
local $Trog::ChangedPackagedFiles::STATE_DIR    = $dir;
local $Trog::ChangedPackagedFiles::EXPECTED_DIR = "$dir/expected";
local $Trog::ChangedPackagedFiles::DPKG_STATUS  = "$dir/dpkg.status";
use warnings FATAL => 'all';

# What the next run of the package manager writes: its standard output, its
# standard error, and its wait status.
my ( @out, @err, $status );
my @ran;
my $mock = Test::MockModule->new( 'Trog::ChangedPackagedFiles', no_auto => 1 );
$mock->redefine( run => sub { push @ran, "@_"; return ( [@out], [@err], $status ) } );

# The wait status of a command that exited with $code.
sub exited {
    my ($code) = @_;
    return $code << 8;
}

# Runs the script once, and returns what it prints and what it dies with.
sub check {
    my ( $stdout, $stderr, $died ) = capture {
        exception { Trog::ChangedPackagedFiles::main() };
    };
    is( $stderr, '', 'it writes nothing to its standard error' );
    return ( $stdout, $died );
}

# The files that a run printed as new.
sub reported {
    my ($stdout) = @_;
    return [ grep { m{\A/} } split( m/\n/, $stdout ) ];
}

subtest 'debsums' => sub {
    @out    = qw{/usr/bin/bogus /usr/share/bogus/data};
    @err    = ();
    $status = exited(2);
    my ($said) = check();
    is( $ran[-1], 'debsums -c', 'it asks debsums on a guest with dpkg' );
    like( $said, qr/\ADANGER:[^\n]*packaged \s files/, 'a changed file is reported' );
    is_deeply( reported($said), [qw{/usr/bin/bogus /usr/share/bogus/data}], 'with each file that debsums reports' );
    like( $said, qr/debsums \s -c \s [|] \s xargs/, 'and how to find the packages to reinstall' );

    is( ( check() )[0], '', 'a file that is still changed is not reported again' );

    @out = qw{/usr/bin/bogus};
    is( ( check() )[0], '', 'a file that returns to its package is not reported' );

    @out = qw{/usr/bin/bogus /usr/share/bogus/data /usr/lib/bogus.so};
    is_deeply( reported( ( check() )[0] ), [qw{/usr/lib/bogus.so /usr/share/bogus/data}], 'and when it changes again it is new, beside a file that changed for the first time' );
};

subtest 'expected changes' => sub {
    File::Slurper::Temp::write_text( "$dir/expected/lexicon",      "# The patches of lexicon.\n/usr/lib/bogus/patched.py\n\n  /usr/lib/bogus/also.py  # and this\n" );
    File::Slurper::Temp::write_text( "$dir/expected/.lexicon.swp", "/usr/lib/bogus/hidden.py\n" );

    @out    = qw{/usr/lib/bogus/patched.py /usr/lib/bogus/also.py /usr/lib/bogus/hidden.py};
    @err    = ();
    $status = exited(2);
    is_deeply( reported( ( check() )[0] ), ['/usr/lib/bogus/hidden.py'], 'a file in the expected list is not reported, and a hidden list is not read' );

    unlink "$dir/expected/lexicon" or die "Cannot remove $dir/expected/lexicon: $!";
    is_deeply( reported( ( check() )[0] ), [qw{/usr/lib/bogus/also.py /usr/lib/bogus/patched.py}], 'and once it leaves the list it is reported' );
};

subtest 'the standard error of debsums' => sub {
    @out = ();
    @err = (
        'debsums: no md5sums for bogus-package',
        'debsums: no md5sums for bogus-other and no deb available',
        'debsums: missing file /usr/bin/gone with space (from bogus package)',
        q{debsums: can't open bogus file /usr/bin/locked (Permission denied)},
    );
    $status = exited(2);
    is_deeply( reported( ( check() )[0] ), [ '/usr/bin/gone with space', '/usr/bin/locked' ], 'a file that is missing or that debsums cannot read is reported, and a package with no checksums is not' );
};

subtest 'a check that stops' => sub {
    @out    = qw{/usr/bin/bogus};
    @err    = ();
    $status = exited(2);
    check();

    # Before the package with no list, debsums found nothing.
    @out    = ();
    @err    = ('Cannot find md5sums path for bogus');
    $status = exited(2);
    my ( $said, $died ) = check();
    is( $said, '',    'a check that stops once reports nothing' );
    is( $died, undef, 'and does not die' );

    @out = qw{/usr/bin/bogus};
    @err = ();
    is( ( check() )[0], '', 'and leaves the state alone, so what it did not reach is not new at the next run' );

    @out    = ();
    @err    = ('Cannot find md5sums path for bogus');
    $status = 0;
    check();
    ( $said, $died ) = check();
    my ( $headline, @said ) = split( m/\n/, $died // q{} );
    like( $headline, qr/stopped \s at \s this \s run \s and \s the \s last/, 'a check that stops at two runs in a row dies' );
    is_deeply( \@said, ['Cannot find md5sums path for bogus'], 'with what debsums said' );

    @err    = ();
    $status = 9;
    check();
    ( undef, $died ) = check();
    like( $died, qr/debsums \s exited \s with \s status \s 9/, 'and so does one that a signal kills, with no message' );
};

subtest 'rpm' => sub {
    unlink "$dir/dpkg.status", "$dir/changed_packaged_files.log", "$dir/changed_packaged_files.stopped";

    @out    = ( 'S.5....T.  c /etc/bogus.conf', 'missing     /usr/bin/bogus', '.......T.    /usr/share/bogus data', 'Unsatisfied dependencies for bogus: bogus-lib' );
    @err    = ();
    $status = exited(1);
    my ($said) = check();
    is( $ran[-1], 'rpm -Va', 'it asks rpm on a guest without dpkg' );
    is_deeply( reported($said), [ '/etc/bogus.conf', '/usr/bin/bogus', '/usr/share/bogus data' ], 'and reports each file that rpm says does not verify' );
    like( $said, qr/rpm \s -qf/, 'with how to find its package' );

    @err = ('error: bogus');
    my $died;
    check();
    ( undef, $died ) = check();
    like( $died, qr/error: \s bogus/, 'a check that rpm complains about at two runs in a row dies' );
};

subtest 'run' => sub {
    $mock->unmock('run');
    my ( $out, $err, $code ) = Trog::ChangedPackagedFiles::run( 'sh', '-c', 'echo out; echo err >&2; exit 3' );
    is_deeply( [ $out, $err, $code >> 8 ], [ ['out'], ['err'], 3 ], 'run keeps the standard output and the standard error apart, with the exit status' );
};

had_no_warnings();
done_testing();
