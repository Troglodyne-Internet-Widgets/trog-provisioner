#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/perllsp-shim.t - the C<perlnavigator> wrapper and the C<perl> shim that the perllsp recipe installs

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Copy qw{copy};
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $files = "$FindBin::Bin/../templates/files";
my $root  = tempdir( CLEANUP => 1 );

# The layout that the recipe installs: the wrapper in sbin, the shim in
# lib/perlnavigator-shim beside it.
make_path( "$root/sbin", "$root/lib/perlnavigator-shim", "$root/fake" );
install( "$files/perllsp.perlnavigator", "$root/sbin/perlnavigator" );
install( "$files/perllsp.perl-shim",     "$root/lib/perlnavigator-shim/perl" );

# Stand-ins for the real perl and the real server.  Each prints what it was
# given, so the assertions read what the shim or the wrapper passed on.
my $REPORT = <<'SH';
#!/bin/sh
printf 'PERLCRITIC=%s\n' "${PERLCRITIC-unset}"
printf 'PATH0=%s\n' "${PATH%%:*}"
for a in "$@"; do printf 'ARG=%s\n' "$a"; done
SH
File::Slurper::Temp::write_text( "$root/fake/perl",          $REPORT );
File::Slurper::Temp::write_text( "$root/fake/perlnavigator", $REPORT );
chmod 0755, "$root/fake/perl", "$root/fake/perlnavigator";

# A checkout with a profile at its root and a second one in scripts/, below a
# directory whose profile must never be reached.
make_path( "$root/above/repo/.git", "$root/above/repo/lib/Deep", "$root/above/repo/scripts" );
touch("$root/above/.perlcriticrc");
touch("$root/above/repo/.perlcriticrc");
touch("$root/above/repo/scripts/.perlcriticrc");
touch("$root/above/repo/lib/Deep/Mod.pm");
touch("$root/above/repo/scripts/tool.pl");

# A worktree, whose .git is a file, and which has no profile of its own.
make_path("$root/above/wt/lib");
touch("$root/above/wt/.git");
touch("$root/above/wt/lib/Mod.pm");

my $PATH = "$root/lib/perlnavigator-shim:$root/fake:/usr/bin:/bin";

sub run_shim {
    my ( $env, @args ) = @_;
    local %ENV = ( %ENV, PATH => $PATH, %$env );
    delete $ENV{PERLCRITIC} unless exists $env->{PERLCRITIC};
    IPC::Run3::run3( [ "$root/lib/perlnavigator-shim/perl", @args ], \undef, \my $out, \my $err );
    is( $? >> 8, 0, "the shim ran @args" ) or diag $err;
    return report($out);
}

sub critic {
    my ( $file, @more ) = @_;
    return run_shim( {}, '/bogus/criticWrapper.pl', @more, '--file', $file );
}

subtest 'a criticWrapper.pl run gets the profile of its file' => sub {
    is( critic("$root/above/repo/lib/Deep/Mod.pm")->{PERLCRITIC}, "$root/above/repo/.perlcriticrc",         'the nearest one above the file' );
    is( critic("$root/above/repo/scripts/tool.pl")->{PERLCRITIC}, "$root/above/repo/scripts/.perlcriticrc", 'one beside the file wins over the root one' );
    is( critic("$root/above/wt/lib/Mod.pm")->{PERLCRITIC},        'unset',                                  'none above the root of a worktree, whose .git is a file' );

    my $r = critic("$root/above/repo/lib/Deep/Mod.pm");
    is( $r->{PATH0}, "$root/fake", 'and the real perl runs without the shim first on PATH' );
    is_deeply( $r->{ARG}, [ '/bogus/criticWrapper.pl', '--file', "$root/above/repo/lib/Deep/Mod.pm" ], 'with the arguments unchanged' );
};

subtest 'a profile that is already chosen is left alone' => sub {
    is( critic( "$root/above/repo/lib/Deep/Mod.pm", '--profile', '/bogus/rc' )->{PERLCRITIC}, 'unset', 'not with --profile' );
    is(
        run_shim( { PERLCRITIC => '/bogus/env-rc' }, '/bogus/criticWrapper.pl', '--file', "$root/above/repo/lib/Deep/Mod.pm" )->{PERLCRITIC},
        '/bogus/env-rc', 'and not when PERLCRITIC is set'
    );
};

subtest 'every other perl run passes through' => sub {
    my $r = run_shim( {}, '-c', "$root/above/repo/lib/Deep/Mod.pm" );
    is( $r->{PERLCRITIC}, 'unset', 'with no PERLCRITIC' );
    is_deeply( $r->{ARG}, [ '-c', "$root/above/repo/lib/Deep/Mod.pm" ], 'and the arguments unchanged' );
};

subtest 'the wrapper starts the real server with the shim first on PATH' => sub {
    local %ENV = ( %ENV, PATH => "$root/sbin:$root/fake:/usr/bin:/bin" );
    IPC::Run3::run3( [ "$root/sbin/perlnavigator", '--stdio' ], \undef, \my $out, \my $err );
    is( $? >> 8, 0, 'it ran' ) or diag $err;
    my $r = report($out);
    is( $r->{PATH0}, "$root/lib/perlnavigator-shim", 'the shim is first on PATH' );
    is_deeply( $r->{ARG}, ['--stdio'], 'and the arguments reach the server' );

    local $ENV{PATH} = "$root/sbin:/usr/bin:/bin";
    IPC::Run3::run3( [ "$root/sbin/perlnavigator", '--stdio' ], \undef, \my $none, \my $why );
    is( $? >> 8, 127, 'with no other perlnavigator on PATH, it exits 127 rather than start itself' );
    like( $why, qr/no[ ]real[ ]perlnavigator/, 'and says why' );
};

sub report {
    my ($out) = @_;
    my %r = ( ARG => [] );
    foreach my $line ( split( m/\n/, $out // '' ) ) {
        my ( $k, $v ) = $line =~ m/\A(\w+)=(.*)\z/ or next;
        if ( $k eq 'ARG' ) { push( @{ $r{ARG} }, $v ) }
        else               { $r{$k} = $v }
    }
    return \%r;
}

sub install {
    my ( $from, $to ) = @_;
    copy( $from, $to ) or die "Could not copy $from to $to: $!\n";
    chmod 0755, $to;
    return;
}

sub touch {
    my ($path) = @_;
    File::Slurper::Temp::write_text( $path, q{} );
    return;
}

Test::NoWarnings::had_no_warnings();
done_testing();
