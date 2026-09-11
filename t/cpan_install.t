#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

# The script is loaded when the test runs rather than when it compiles, so perl
# sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/cpan_install.t - scripts/cpan_install: through the cache when it answers,
around it when it does not, and each verb a recipe can declare

=cut

use Test::More;
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/cpan_install";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $CACHE = 'http://cache.test.test';
my $PINS  = "$CACHE/fastapi.metacpan.org/v1/download_url/Sys::Virt?version===10.0.0";

# A perl to install into, which is only its bin directory and a cpanm in it.
my $PERL = tempdir( CLEANUP => 1 );
mkdir "$PERL/bin";
for my $tool (qw{cpanm dzil}) {
    open( my $fh, '>', "$PERL/bin/$tool" ) or die $!;
    close $fh;
    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    chmod( 0755, "$PERL/bin/$tool" );
}
my $CPANM = "$PERL/bin/cpanm";

# One run of cpan_install, with every command it would have run written down
# rather than run, and HTTP::Tiny answering from %http.  %capture says what a
# captured command prints, by its first two words.
sub install {
    my (%case) = @_;

    my $root = tempdir( CLEANUP => 1 );
    local $Trog::Script::CpanInstall::CPANM_LINK = $CPANM;
    local $Trog::Script::CpanInstall::ROOT_BIN   = $root;
    local $Trog::Script::CpanInstall::CACHE_FILE = "$root/no-cache-file";

    # Whether the cache answered is kept for one run, and each case is one run.
    local %Trog::Script::CpanInstall::CACHE_UP;
    delete local $ENV{TROG_CACHE};
    $ENV{TROG_CACHE} = $case{cache} if exists $case{cache};

    my ( @ran, @asked );

    # no_auto: it was loaded from its path above, so there is no module file to load.
    my $script = Test::MockModule->new( 'Trog::Script::CpanInstall', no_auto => 1 );
    $script->redefine( run_in     => sub { my ( $dir, @cmd ) = @_; push @ran, [ $dir, @cmd ]; return $case{fails} && $cmd[0] =~ $case{fails} ? 1 : 0 } );
    $script->redefine( capture_in => sub { my ( $dir, @cmd ) = @_; push @ran, [ $dir, @cmd ]; return @{ $case{capture}{"@cmd[0,1]"} // [] } } );

    my $http = Test::MockModule->new('HTTP::Tiny');
    $http->redefine(
        get => sub {
            my ( undef, $url ) = @_;
            push @asked, $url;
            return $case{http}{$url} // { success => 0, status => 599, content => q{} };
        }
    );

    my ( $out, $err ) = ( q{}, q{} );
    my $rc;
    {
        local *STDOUT;
        local *STDERR;
        open( STDOUT, '>', \$out ) or die $!;
        open( STDERR, '>', \$err ) or die $!;

        $rc = Trog::Script::CpanInstall::main( @{ $case{args} } );
    }
    return { rc => $rc, ran => \@ran, asked => \@asked, out => $out, err => $err, root => $root };
}

sub up { return ( "$CACHE/fetchcache-status" => { success => 1, status => 200, content => "ok\n" } ) }

subtest 'through the cache when it answers' => sub {
    my $r = install( cache => $CACHE, http => { up() }, args => [qw{--notest install Moo}] );

    is( $r->{rc}, 0, 'it succeeds' );
    is_deeply(
        $r->{ran},
        [ [ undef, $CPANM, '--notest', '--mirror', "$CACHE/www.cpan.org", qw{--mirror https://www.cpan.org --mirror-only Moo} ] ],
        'the cache as the first mirror, CPAN behind it, and the index read from them rather than from MetaCPAN'
    );
    is_deeply( $r->{asked}, ["$CACHE/fetchcache-status"], 'having asked the cache once whether it was there' );
};

subtest 'around the cache when it does not' => sub {
    my $r = install( cache => $CACHE, args => [qw{install Moo}] );

    is_deeply( $r->{ran}, [ [ undef, $CPANM, 'Moo' ] ], 'cpanm as it would run with no cache at all' );
    like( $r->{out}, qr/not answering, so straight to CPAN/, 'saying why' );

    $r = install( args => [qw{install Moo}] );
    is_deeply( $r->{asked}, [],                           'and with none configured, nothing is asked' );
    is_deeply( $r->{ran},   [ [ undef, $CPANM, 'Moo' ] ], 'and nothing is added' );
};

subtest 'the test suites run unless told not to' => sub {
    my $r = install( args => [qw{install Moo}] );
    ok( !( grep { defined && $_ eq '--notest' } @{ $r->{ran}[0] } ), 'no --notest unless asked for' );
};

subtest 'a pinned version becomes the path cpanm fetches from the mirror' => sub {
    my $found = { success => 1, status => 200, content => '{"download_url":"https://cpan.metacpan.org/authors/id/D/DA/DANBERR/Sys-Virt-v10.0.0.tar.gz"}' };
    my $r     = install( cache => $CACHE, http => { up(), $PINS => $found }, args => [ qw{install Sys::Virt@10.0.0}, 'Moo~>= 2.004' ] );

    is( $r->{ran}[0][-2], 'DANBERR/Sys-Virt-v10.0.0.tar.gz', 'looked up through the cache copy of MetaCPAN' );
    is( $r->{ran}[0][-1], 'Moo~>= 2.004',                    'while a version requirement is handed on as it was, as one word' );
    like( $r->{out}, qr/Sys::Virt\@10\.0\.0 is DANBERR/, 'saying what it became' );

    $r = install( cache => $CACHE, http => { up() }, args => [qw{install Sys::Virt@10.0.0}] );
    is( $r->{ran}[0][-1], 'Sys::Virt@10.0.0', 'and one it could not look up is handed to cpanm as written' );
    like( $r->{err}, qr/could not look Sys::Virt\@10\.0\.0 up/, 'which it says' );

    $r = install( args => [qw{install Sys::Virt@10.0.0}] );
    is_deeply( $r->{asked}, [], 'with no cache there is nothing to look it up through' );
};

subtest 'installdeps and dzil' => sub {
    my $r = install( args => [qw{--notest installdeps /bogus/app}] );
    is_deeply( $r->{ran}, [ [ undef, $CPANM, qw{--notest --installdeps /bogus/app} ] ], 'installdeps is what the distribution says it needs' );

    $r = install(
        args    => [qw{dzil /bogus/checkout}],
        capture => { "$PERL/bin/dzil authordeps" => [ "Dist::Zilla::Plugin::Git\n", "\n" ], "$PERL/bin/dzil listdeps" => ["Moo\n"] },
    );
    is_deeply(
        $r->{ran},
        [ [ '/bogus/checkout', "$PERL/bin/dzil", qw{authordeps --missing} ], [ undef, $CPANM, 'Dist::Zilla::Plugin::Git' ], [ '/bogus/checkout', "$PERL/bin/dzil", qw{listdeps --missing} ], [ undef, $CPANM, 'Moo' ], ],
        'the plugins dist.ini names, then what they say the distribution needs, asked in the checkout'
    );

    $r = install( args => [qw{dzil /bogus/checkout}] );
    is( scalar( grep { $_->[1] eq $CPANM } @{ $r->{ran} } ), 0, 'and nothing missing is nothing to install' );
};

subtest 'pin: the version pkg-config reports, asked when it runs' => sub {
    my $r = install( args => [qw{pin libvirt Sys::Virt}], capture => { 'pkg-config --modversion' => ["10.0.0\n"] } );
    is_deeply( $r->{ran}[-1], [ undef, $CPANM, 'Sys::Virt@10.0.0' ], 'the module at that version' );

    $r = install( args => [qw{pin libvirt Sys::Virt}] );
    is( $r->{rc}, 1, 'pkg-config knowing nothing is a failure' );
    like( $r->{err}, qr/pkg-config knows no libvirt/, 'saying so, rather than installing the newest' );
};

subtest 'a tool is linked once the step that installs it has worked' => sub {
    my $r = install( args => [qw{--link dzil install Dist::Zilla}] );
    is( readlink("$r->{root}/dzil"), "$PERL/bin/dzil", 'into /root/bin, pointing into the perl' );

    $r = install( args => [qw{--link dzil install Dist::Zilla}], fails => qr/cpanm/ );
    is( $r->{rc}, 1, 'a failed install is the exit code' );
    ok( !-l "$r->{root}/dzil", 'and nothing is linked to what it did not install' );
};

subtest 'a new perl is given its cpanm from the tarball' => sub {
    my $r = install( args => [qw{--bootstrap /bogus/perl/bin/perl}] );

    my @what = map {
        join( ' ', grep { defined } @$_[ 1 .. 2 ] )
    } @{ $r->{ran} };
    is_deeply( \@what, [ "$Trog::Script::CpanInstall::FETCH $Trog::Script::CpanInstall::CPANMINUS", 'tar -xzf', '/bogus/perl/bin/perl Makefile.PL', 'make', 'make install' ], 'fetched through scripts/fetch, and built by that perl' );
};

subtest 'it has to be told what to do' => sub {
    is( install( args => [] )->{rc},                 2, 'no verb is a usage error' );
    is( install( args => [qw{frobnicate x}] )->{rc}, 2, 'and so is one it does not know' );
};

done_testing();
