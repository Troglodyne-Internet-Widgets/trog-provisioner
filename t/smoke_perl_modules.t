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
use Cpanel::JSON::XS();
use Test::MockModule();

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

# Runs the script against stand-ins for cpan_install, conformance and the
# installer of the packager, which write each call to one log.  cpan_install
# fails the verbs in $fails.  conformance prints the packages that $declared
# names for a checkout, fails for one that it names as undef, and writes
# nothing to the log for the rest, which declare nothing.  The installer fails
# when $install_fails is true.  $forks are the names that the cache of
# repos_for records as forks.  Returns the exit code, what the script printed
# to stderr, and each call as a list of its words, with the base directory
# taken off, in the order made.
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

    my $declared = $opts{declared} // {};
    File::Slurper::Temp::write_text( "$bin/declared", join q{}, map { "$_ " . ( $declared->{$_} // 'FAIL' ) . "\n" } keys %$declared );
    File::Slurper::Temp::write_text( "$bin/conformance", <<"FAKE" );
#!$^X
my ( \$verb, \$dir ) = \@ARGV;
my (\$name) = \$dir =~ m{([^/]+)\\z};
open( my \$in, '<', '$bin/declared' ) or die \$!;
my %declared = map { chomp; split( ' ', \$_, 2 ) } <\$in>;
exit 0 unless exists \$declared{\$name};
open( my \$fh, '>>', '$log' ) or die \$!;
print {\$fh} "conformance \$verb \$dir\\n";
close(\$fh) or die \$!;
exit 2 if \$declared{\$name} eq 'FAIL';
print "\$_\\n" for split ' ', \$declared{\$name};
exit 0;
FAKE
    File::Slurper::Temp::write_text( "$bin/install", <<"FAKE" );
#!$^X
open( my \$fh, '>>', '$log' ) or die \$!;
print {\$fh} "install \@ARGV\\n";
close(\$fh) or die \$!;
exit( \$ENV{SMOKE_INSTALL_FAILS} ? 100 : 0 );
FAKE
    for my $fake (qw{cpan_install conformance install}) {
        chmod 0755, "$bin/$fake" or die "Cannot make the stand-in $fake executable: $!";
    }

    my $forks = $opts{forks} // [];
    File::Slurper::Temp::write_text( "$bin/repos_for.json", Cpanel::JSON::XS->new->encode( { 'https://api.test' => { entity => { map { $_ => { fork => 1 } } @$forks } } } ) );

    local $ENV{SMOKE_FAILS}         = $opts{fails}         // '';
    local $ENV{SMOKE_INSTALL_FAILS} = $opts{install_fails} // '';
    my @options = ( '--forks', "$bin/repos_for.json", "--conformance-command=$^X", "--conformance-command=$bin/conformance", "--install-command=$bin/install", '--install-command=-y' );
    IPC::Run3::run3( [ $^X, $script, @options, $base, "$bin/cpan_install", @{ $opts{flags} // [] } ], \undef, \my $out, \my $err );
    my $rc = $?;

    my @calls = -e $log ? map { [ split ' ', s{\Q$base\E/}{}gr ] } split /\n/, File::Slurper::read_text($log) : ();
    return ( $rc, $err, @calls );
}

subtest 'each checkout gets the installer that its build system needs' => sub {
    my $base = tempdir( CLEANUP => 1 );
    checkout( $base, qw{a-dzil dist.ini Makefile.PL} );
    checkout( $base, qw{b-eumm Makefile.PL} );
    checkout( $base, qw{c-mb Build.PL} );
    checkout( $base, qw{d-none README} );
    checkout( $base, qw{e-untested Makefile.PL no-t} );

    my ( $rc, undef, @calls ) = smoke( $base, flags => ['--notest'] );
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

    my ( $rc, undef, @calls ) = smoke( $base, fails => 'test' );
    isnt( $rc, 0, 'it exits non-zero' );
    is( scalar( grep { $_->[0] eq 'test' } @calls ), 2, 'and still tests every checkout' );
};

subtest 'dependencies fail to install' => sub {
    my $base = tempdir( CLEANUP => 1 );
    checkout( $base, qw{a-dzil dist.ini} );

    my ( $rc, undef, @calls ) = smoke( $base, fails => 'dzil' );
    isnt( $rc, 0, 'it exits non-zero' );
    is_deeply( \@calls, [ [qw{dzil a-dzil}] ], 'and does not test what it could not install for' );
};

subtest 'a fork is not smoked' => sub {
    my $base = tempdir( CLEANUP => 1 );
    checkout( $base, qw{a-forked Makefile.PL} );
    checkout( $base, qw{b-own Makefile.PL} );

    my ( $rc, $err, @calls ) = smoke( $base, forks => ['a-forked'] );
    is( $rc, 0, 'it exits 0' );
    is_deeply( \@calls, [ [qw{installdeps b-own}], [qw{test b-own}] ], 'and smokes the checkouts that the cache of repos_for does not record as a fork' );
    like( $err, qr{a-forked[ ]is[ ]a[ ]fork}, 'and says which one it left out' );
};

subtest 'the system packages that a checkout declares go in first' => sub {
    my $base = tempdir( CLEANUP => 1 );
    checkout( $base, qw{a-declares dist.ini} );
    checkout( $base, qw{b-plain Makefile.PL} );

    my ( $rc, undef, @calls ) = smoke( $base, declared => { 'a-declares' => 'libfoo-dev ffmpeg' } );
    is( $rc, 0, 'it exits 0' );
    is_deeply(
        [ @calls[ 0 .. 3 ] ],
        [ [qw{conformance packages a-declares}], [qw{install -y libfoo-dev ffmpeg}], [qw{dzil a-declares}], [qw{test a-declares}] ],
        'what conformance names for the host, with the install command, before its CPAN dependencies'
    );
    is_deeply( [ @calls[ 4, 5 ] ], [ [qw{installdeps b-plain}], [qw{test b-plain}] ], 'and a checkout that declares nothing goes straight on' );
};

subtest 'a declaration that does not resolve, or packages that do not install' => sub {
    my $base = tempdir( CLEANUP => 1 );
    checkout( $base, qw{a-bad dist.ini} );
    checkout( $base, qw{b-plain Makefile.PL} );

    my ( $rc, undef, @calls ) = smoke( $base, declared => { 'a-bad' => undef } );
    isnt( $rc, 0, 'a conformance that fails is a failure' );
    is_deeply( \@calls, [ [qw{conformance packages a-bad}], [qw{installdeps b-plain}], [qw{test b-plain}] ], 'and that checkout is not installed or tested, but the next one is' );

    ( $rc, undef, @calls ) = smoke( $base, declared => { 'a-bad' => 'libfoo-dev' }, install_fails => 1 );
    isnt( $rc, 0, 'and so is an install that fails' );
    is_deeply( [ map { $_->[0] } @calls[ 2 .. 3 ] ], [qw{installdeps test}], 'which also leaves only the next checkout to go on' );
};

subtest 'the options are required' => sub {
    my $base = tempdir( CLEANUP => 1 );
    IPC::Run3::run3( [ $^X, $script, $base, '/bogus/cpan_install' ], \undef, \my $out, \my $err );
    isnt( $?, 0, 'it refuses to run without them' );
    like( $err, qr{--forks}, 'and names what it needs' );
};

require_ok($script);

subtest 'the tests run as the owner of the checkout' => sub {
    is_deeply( [ Trog::Script::SmokePerlModules::as_owner($<) ], [], 'and as they are when this account owns it' );

    # The test needs an account other than its own, and root is on every host.
    plan skip_all => 'this runs as root, so root is not another account' unless $<;
    is_deeply( [ Trog::Script::SmokePerlModules::as_owner(0) ], [qw{--as root}], 'through cpan_install, which can change the account' );
};

subtest 'what root leaves in a checkout goes back to its owner' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/.git");
    File::Slurper::Temp::write_text( "$dir/$_", "# bogus\n" ) for qw{Makefile .git/index};
    symlink( "$dir/Makefile", "$dir/link" ) or die "Cannot make the symlink: $!";

    my $mock = Test::MockModule->new( 'Trog::Script::SmokePerlModules', no_auto => 1 );
    my @given;
    $mock->redefine( set_owner => sub { push @given, [ $_[0] =~ s{\A\Q$dir\E}{}r, @_[ 1, 2 ] ] } );

    # $< stands for root, because every file here belongs to the account that
    # runs the test.
    Trog::Script::SmokePerlModules::give_back( $dir, $<, 4242, 4343 );
    is_deeply( [ sort { $a->[0] cmp $b->[0] } @given ], [ map { [ $_, 4242, 4343 ] } q{}, qw{/.git /.git/index /Makefile /link} ], 'every file, directory and symlink' );

    # The basedir can hold a checkout through a symlink, which glob and -d take.
    @given = ();
    my $links = tempdir( CLEANUP => 1 );
    symlink( $dir, "$links/checkout" ) or die "Cannot make the symlink: $!";
    Trog::Script::SmokePerlModules::give_back( "$links/checkout", $<, 4242, 4343 );
    is( scalar @given, 5, 'and through a checkout that is a symlink' );

    @given = ();
    Trog::Script::SmokePerlModules::give_back( $dir, $< + 1, 4242, 4343 );
    is_deeply( \@given, [], 'and nothing that another account owns' );

    Trog::Script::SmokePerlModules::give_back( $dir, $<, $<, 4343 );
    is_deeply( \@given, [], 'and nothing when the owner ran the install' );
};

subtest 'a symlink is given, not what it points at' => sub {

    # A chown that followed this link would fail, because nothing is there.
    my $dir = tempdir( CLEANUP => 1 );
    symlink( '/bogus/nothing', "$dir/dangling" ) or die "Cannot make the symlink: $!";

    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    Trog::Script::SmokePerlModules::set_owner( "$dir/dangling", $<, $( + 0 );
    is_deeply( \@warned, [], 'the owner of the link changes, and its target is never touched' );
};

subtest 'the PATH of an interactive bash of the owner' => sub {
    my $home = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$home/.bashrc", <<'RC' );
[ -z "$PS1" ] && return
echo 'PATH=/bogus/printed/by/a/startup/file'
printf 'a line with no newline'
export PATH="/bogus/owner/node/bin:$PATH"
RC

    my $path = Trog::Script::SmokePerlModules::interactive_path( 'env', "HOME=$home" );
    like( $path, qr{\A/bogus/owner/node/bin:}, 'is what its startup files leave, and not what they print' );

    is( Trog::Script::SmokePerlModules::interactive_path('true'), undef, 'and nothing when it prints none' );
    is_deeply( [ Trog::Script::SmokePerlModules::owner_path($<) ], [], 'and nothing asked of the account that runs the script' );
};

subtest 'the PATH of the owner goes first' => sub {
    local $ENV{PATH} = '/bogus/root/bin:/usr/bin';
    is( Trog::Script::SmokePerlModules::path_with('/bogus/owner/bin::/usr/bin'), '/bogus/owner/bin:/usr/bin:/bogus/root/bin', 'with each directory once, and no empty one' );
    is( Trog::Script::SmokePerlModules::path_with(),                             '/bogus/root/bin:/usr/bin',                  'and the PATH as it is without one' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
