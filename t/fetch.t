#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/fetch.t - scripts/fetch: the cache first, upstream when it cannot answer

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/fetch";

## no critic (ValuesAndExpressions::ProhibitFiletest_rwxRWX)
ok( -x $script, 'fetch is there and executable' );

# A curl that fetches nothing.  It writes down every URL it was asked for, so
# what was tried and in which order is a list rather than a guess, and writes
# the URL into the file it was given as the body.  A URL matching
# FAKE_CURL_FAILS writes half a file and fails, the way a download dying part
# way does.
my $bin = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$bin/curl", <<'CURL' );
#!/bin/bash
url=${!#}
out=
while [ $# -gt 0 ]; do
    [ "$1" = -o ] && out=$2
    shift
done
echo "$url" >> "$FAKE_CURL_LOG"
case "$url" in
    $FAKE_CURL_FAILS) echo partial > "$out"; exit 22 ;;
esac
echo "body of $url" > "$out"
CURL
## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
chmod( 0755, "$bin/curl" );

my $URL      = 'https://github.com/o/r/releases/download/v1/x.tgz';
my $UPSTREAM = $URL;
my $CACHED   = 'http://cache.test.test/github.com/o/r/releases/download/v1/x.tgz';

sub run_fetch {
    my (%opts) = @_;

    my $dir = tempdir( CLEANUP => 1 );

    local $ENV{PATH}            = "$bin:$ENV{PATH}";
    local $ENV{FAKE_CURL_LOG}   = "$dir/asked";
    local $ENV{FAKE_CURL_FAILS} = $opts{fails}      // 'no-url-is-this';
    local $ENV{TROG_CACHE_FILE} = $opts{cache_file} // "$dir/no-cache-file";
    delete local $ENV{TROG_CACHE};
    $ENV{TROG_CACHE} = $opts{cache} if exists $opts{cache};

    my @args = $opts{args} ? @{ $opts{args} } : ( $URL, "$dir/x.tgz" );
    IPC::Run3::run3( [ $script, @args ], \undef, \my $out, \my $err );

    return {
        status => $? >> 8,
        out    => $out // q{},
        err    => $err // q{},
        asked  => [ split( "\n", eval { File::Slurper::read_text("$dir/asked") } // q{} ) ],
        got    => scalar eval { File::Slurper::read_text("$dir/x.tgz") },
        left   => [ grep { m/\Ax\.tgz/ } map { s{\A.*/}{}r } glob("$dir/*") ],
    };
}

subtest 'the cache is asked first, for the upstream URL less its scheme' => sub {
    my $r = run_fetch( cache => 'http://cache.test.test' );

    is_deeply( $r->{asked}, [$CACHED], 'the cache, and nothing else once it answered' );
    is( $r->{got},    "body of $CACHED\n", 'what it sent is the file' );
    is( $r->{status}, 0,                   'and it exits clean' );
    like( $r->{out}, qr/from http:\/\/cache\.test\.test/, 'saying where it came from' );
};

subtest 'upstream, when the cache cannot supply it' => sub {
    my $r = run_fetch( cache => 'http://cache.test.test', fails => 'http://cache.test.test/*' );

    is_deeply( $r->{asked}, [ $CACHED, $UPSTREAM ], 'the cache, then upstream' );
    is( $r->{got},    "body of $UPSTREAM\n", 'and the file is what upstream sent, not the half the cache did' );
    is( $r->{status}, 0,                     'which is still a success' );
    like( $r->{err}, qr/could not supply \Q$URL\E; trying upstream/, 'saying the cache failed it' );
};

subtest 'no cache is straight upstream' => sub {
    is_deeply( run_fetch()->{asked}, [$UPSTREAM], 'with nothing configured anywhere' );

    # Set but empty is how a caller says to skip the cache configured on the
    # machine, and has to win over the file.
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = "$dir/cache_uri";
    File::Slurper::Temp::write_text( $file, "http://cache.test.test\n" );
    is_deeply( run_fetch( cache => q{}, cache_file => $file )->{asked}, [$UPSTREAM], 'and with TROG_CACHE set empty over a configured one' );
};

subtest 'the file on the guest names the cache' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = "$dir/cache_uri";
    File::Slurper::Temp::write_text( $file, "http://cache.test.test\n" );

    is_deeply( run_fetch( cache_file => $file )->{asked}, [$CACHED], 'read, trailing newline and all, when the environment says nothing' );
};

subtest 'both failing is a failure, and leaves nothing behind' => sub {
    my $r = run_fetch( cache => 'http://cache.test.test', fails => '*' );

    is( $r->{status}, 1, 'it exits non-zero' );
    like( $r->{err}, qr/could not download \Q$URL\E/, 'naming what it could not get' );

    # The half file each failed attempt wrote is exactly what a later step must
    # not find and take for the download.
    is_deeply( $r->{left}, [], 'and neither the file nor the half of one it was writing is there' );
};

subtest 'it has to be told what and where' => sub {
    my $r = run_fetch( args => [$URL] );
    is( $r->{status}, 2, 'one argument is a usage error' );
    is_deeply( $r->{asked}, [], 'and nothing is fetched' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
