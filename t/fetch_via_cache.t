#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/fetch_via_cache.t - scripts/fetch_via_cache: which hosts it points at the
fetch cache, and that it gives every one of them back

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/fetch_via_cache";

## no critic (ValuesAndExpressions::ProhibitFiletest_rwxRWX)
ok( -x $script, 'fetch_via_cache is there and executable' );

# A curl that asks nothing: it succeeds for a host named in FAKE_CACHE_HOSTS,
# which is the cache answering for it, and fails for any other.  It and
# update-ca-certificates write down how they were called, so what was asked is a
# list rather than a guess.
my $bin = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$bin/curl", <<'CURL' );
#!/bin/bash
echo "curl $*" >> "$FAKE_LOG"
url=${!#}
host=${url#https://}
host=${host%%/*}
case " $FAKE_CACHE_HOSTS " in
    *" $host "*) exit 0 ;;
esac
exit 22
CURL
File::Slurper::Temp::write_text( "$bin/update-ca-certificates", <<'UPDATE' );
#!/bin/bash
echo "update-ca-certificates" >> "$FAKE_LOG"
UPDATE
## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
chmod( 0755, "$bin/curl", "$bin/update-ca-certificates" );
## use critic

my $HOSTS = "127.0.0.1\tlocalhost\n192.168.1.5\tguest.test.test guest\n";
my $CACHE = '192.168.1.9';

# A guest's /etc/hosts and an authority to hand it, in a directory of their own.
sub guest {
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/hosts",  $HOSTS );
    File::Slurper::Temp::write_text( "$dir/ca.crt", "an authority\n" );
    return $dir;
}

sub run_it {
    my ( $dir, $answers, @args ) = @_;

    local $ENV{PATH}                   = "$bin:$ENV{PATH}";
    local $ENV{FAKE_LOG}               = "$dir/log";
    local $ENV{FAKE_CACHE_HOSTS}       = join( q{ }, @$answers );
    local $ENV{FETCH_VIA_CACHE_HOSTS}  = "$dir/hosts";
    local $ENV{FETCH_VIA_CACHE_ANCHOR} = "$dir/anchor.crt";
    unlink "$dir/log";

    IPC::Run3::run3( [ $script, @args ], \undef, \my $out, \my $err );

    return {
        status => $? >> 8,
        out    => $out // q{},
        err    => $err // q{},
        hosts  => File::Slurper::read_text("$dir/hosts"),
        log    => [ split( "\n", eval { File::Slurper::read_text("$dir/log") } // q{} ) ],
    };
}

sub block {
    my (@hosts) = @_;
    return join( q{}, "# BEGIN trog fetchcache\n", ( map { "$CACHE\t$_\n" } @hosts ), "# END trog fetchcache\n" );
}

subtest 'on: the hosts the cache answers for, and no others' => sub {
    my $dir = guest();
    my $run = run_it( $dir, [qw{www.cpan.org codeload.github.com}], 'on', $CACHE, "$dir/ca.crt", qw{www.cpan.org codeload.github.com github.com} );

    is( $run->{status}, 0,                                                    'it exits zero' );
    is( $run->{hosts},  $HOSTS . block(qw{www.cpan.org codeload.github.com}), 'the two it answers for point at it, after what was already there' );
    like( $run->{err}, qr/\Q$CACHE\E does not answer for github\.com, so it comes from upstream/, 'and the one it does not is left alone, saying so' );
    like( $run->{out}, qr/through the cache at \Q$CACHE\E: www\.cpan\.org codeload\.github\.com/, 'saying which went through it' );

    is( File::Slurper::read_text("$dir/anchor.crt"),                  "an authority\n", 'the authority is trusted' );
    is( ( grep { $_ eq 'update-ca-certificates' } @{ $run->{log} } ), 1,                'and the trust store rebuilt with it' );

    # By name, at the address, and trusting nothing but the authority: what the
    # guest will do once /etc/hosts says so, asked before it does.
    my ($asked) = grep { index( $_, 'www.cpan.org' ) >= 0 } @{ $run->{log} };
    like( $asked, qr{--resolve www\.cpan\.org:443:\Q$CACHE\E --cacert \Q$dir\E/ca\.crt https://www\.cpan\.org/fetchcache-status\z}, 'each asked for by name, at the cache, trusting the authority alone' );
};

subtest 'on twice: the second answer replaces the first' => sub {
    my $dir = guest();
    run_it( $dir, [qw{www.cpan.org github.com}], 'on', $CACHE, "$dir/ca.crt", qw{www.cpan.org github.com} );
    my $again = run_it( $dir, ['github.com'], 'on', $CACHE, "$dir/ca.crt", qw{www.cpan.org github.com} );

    is( $again->{hosts}, $HOSTS . block('github.com'), 'one block, as the cache answered this time' );
};

subtest 'a cache that answers for nothing changes nothing in /etc/hosts' => sub {
    my $dir = guest();
    my $run = run_it( $dir, [], 'on', $CACHE, "$dir/ca.crt", qw{www.cpan.org github.com} );

    is( $run->{status}, 0,      'and is no reason to fail' );
    is( $run->{hosts},  $HOSTS, 'every host still goes upstream' );
    like( $run->{out}, qr/through the cache at \Q$CACHE\E: nothing/, 'which it says' );
};

subtest 'off gives every host back, and the authority with them' => sub {
    my $dir = guest();
    run_it( $dir, [qw{www.cpan.org github.com}], 'on', $CACHE, "$dir/ca.crt", qw{www.cpan.org github.com} );
    my $off = run_it( $dir, [], 'off' );

    is( $off->{status}, 0,      'it exits zero' );
    is( $off->{hosts},  $HOSTS, '/etc/hosts is as it was, every other line kept' );
    ok( !-e "$dir/anchor.crt", 'the authority is no longer trusted' );
    is_deeply( $off->{log}, ['update-ca-certificates'], 'the trust store rebuilt without it, and the cache not asked anything' );

    my $twice = run_it( $dir, [], 'off' );
    is( $twice->{status}, 0,      'and with nothing left to give back it is harmless' );
    is( $twice->{hosts},  $HOSTS, 'changing nothing' );
};

subtest 'told nothing it can use, it says how and changes nothing' => sub {
    my $dir = guest();

    my $none = run_it( $dir, [], );
    is( $none->{status}, 2, 'no verb is a usage error' );
    like( $none->{err}, qr/usage: fetch_via_cache on ADDRESS AUTHORITY HOST/, 'saying what it takes' );

    my $missing = run_it( $dir, ['www.cpan.org'], 'on', $CACHE, "$dir/no-such-authority", 'www.cpan.org' );
    is( $missing->{status}, 2,      'nor is an authority that is not there' );
    is( $missing->{hosts},  $HOSTS, 'and /etc/hosts is left alone' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
