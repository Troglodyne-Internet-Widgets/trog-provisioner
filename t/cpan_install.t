#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

# The script is loaded when the test runs rather than when it compiles, so perl
# sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/cpan_install.t - scripts/cpan_install: each verb a recipe can declare, into
the perl the perl recipe built

=cut

use Test::More;
use Capture::Tiny    qw{capture};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Path       qw{make_path};

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/cpan_install";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# A perl to install into, found the way the script finds one: the newest under
# the root the perl recipe builds into, which is only a bin and the tools in it.
my $PERL_ROOT = tempdir( CLEANUP => 1 );
my $PERL      = "$PERL_ROOT/perl5.44.0";
make_path("$PERL/bin");
for my $tool (qw{cpanm cpm dzil}) {
    open( my $fh, '>', "$PERL/bin/$tool" ) or die $!;
    close($fh)                             or die "Could not close $PERL/bin/$tool: $!";
    chmod( 0755, "$PERL/bin/$tool" );
}
my $CPANM = "$PERL/bin/cpanm";

# cpm, run by that perl, resolving from the index of the mirror alone, and
# without the specs.  --test is added when the suites run.
my @CPM = ( "$PERL/bin/perl", "$PERL/bin/cpm", qw{install --global --final-install all --no-color --progress plain --show-build-log-on-failure --resolver}, '02packages,https://www.cpan.org', '--no-default-resolvers' );

# One run of cpan_install, with every command it would have run written down
# rather than run.  %capture says what a captured command prints and
# %capture_exit what it exits with, both by its first two words; git_config is
# the git command-scope configuration each captured command was run under.
sub install {
    my (%case) = @_;

    local $Trog::Script::CpanInstall::PERL_ROOT = $case{perl_root} // $PERL_ROOT;

    my ( @ran, @git_config );

    # no_auto: it was loaded from its path above, so there is no module file to load.
    my $cpan_install = Test::MockModule->new( 'Trog::Script::CpanInstall', no_auto => 1 );
    $cpan_install->redefine( run_in => sub { my ( $dir, @cmd ) = @_; push @ran, [ $dir, @cmd ]; return $case{fails} && "@cmd" =~ $case{fails} ? 1 : 0 } );
    $cpan_install->redefine(
        capture_in => sub {
            my ( $dir, @cmd ) = @_;
            push @ran,        [ $dir, @cmd ];
            push @git_config, [ @ENV{qw{GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0}} ];
            return ( $case{capture_exit}{"@cmd[0,1]"} // 0, @{ $case{capture}{"@cmd[0,1]"} // [] } );
        }
    );

    my ( $rc, $died );
    my ( $out, $err ) = capture {
        $rc   = eval { Trog::Script::CpanInstall::main( @{ $case{args} } ) };
        $died = $@;
    };
    $err .= $died if $died;
    return { rc => $rc, ran => \@ran, out => $out, err => $err, git_config => \@git_config };
}

subtest 'install: into the newest perl the recipe built' => sub {
    my $r = install( args => [ qw{--notest install Moo Sys::Virt@10.0.0}, 'Moo~>= 2.004' ] );

    is( $r->{rc}, 0, 'it succeeds' );
    is_deeply(
        $r->{ran},
        [ [ undef, $CPANM, qw{--notest Sys::Virt@10.0.0} ], [ undef, @CPM, 'Moo', 'Moo~>= 2.004' ] ],
        'the pin with that perl cpanm first, then the rest with its cpm, each spec handed on as one word'
    );
};

subtest 'the test suites run unless told not to' => sub {
    my $r = install( args => [ qw{install Moo}, 'Sys::Virt@10.0.0' ] );
    is_deeply( $r->{ran}, [ [ undef, $CPANM, 'Sys::Virt@10.0.0' ], [ undef, @CPM, '--test', 'Moo' ] ], 'cpanm has no --notest, and cpm is asked for the tests it skips by default' );
};

subtest 'installdeps and dzil' => sub {
    my $r = install( args => [qw{--notest installdeps /bogus/app}] );
    is_deeply( $r->{ran}, [ [ '/bogus/app', @CPM, '--top-level-phase', 'configure,build,test,runtime' ] ], 'installdeps is what the distribution says it needs, read by cpm in its directory, without what only an author needs' );

    $r = install(
        args    => [qw{dzil /bogus/checkout}],
        capture => { "$PERL/bin/dzil authordeps" => [ "Dist::Zilla::Plugin::Git\n", "\n" ], "$PERL/bin/dzil listdeps" => ["Moo\n"] },
    );
    is_deeply(
        $r->{ran},
        [ [ '/bogus/checkout', "$PERL/bin/dzil", qw{authordeps --missing} ], [ undef, @CPM, '--test', 'Dist::Zilla::Plugin::Git' ], [ '/bogus/checkout', "$PERL/bin/dzil", qw{listdeps --missing} ], [ undef, @CPM, '--test', 'Moo' ], ],
        'the plugins dist.ini names, then what they say the distribution needs, asked in the checkout'
    );

    $r = install( args => [qw{dzil /bogus/checkout}] );
    is( scalar( grep { $_->[1] ne "$PERL/bin/dzil" } @{ $r->{ran} } ), 0, 'and nothing missing is nothing to install' );
};

subtest 'dzil: a checkout root does not own, and a dzil that fails says so' => sub {
    my $r = install( args => [qw{dzil /bogus/checkout}] );
    is_deeply(
        $r->{git_config},
        [ ( [ 1, 'safe.directory', '/bogus/checkout' ] ) x 2 ],
        'git trusts the checkout for both dzil commands, which it would otherwise refuse as owned by the service user'
    );
    ok( !exists $ENV{GIT_CONFIG_COUNT}, 'and for nothing after them' );

    $r = install(
        args         => [qw{dzil /bogus/checkout}],
        capture      => { "$PERL/bin/dzil authordeps" => ["Dist::Zilla::Plugin::Git\n"] },
        capture_exit => { "$PERL/bin/dzil listdeps"   => 128 },
    );
    is( $r->{rc}, 128, 'listdeps failing fails the step, with its exit code' );
    like( $r->{err}, qr{dzil[ ]listdeps[ ]--missing[ ]exited[ ]128[ ]in[ ]/bogus/checkout}, 'naming which dzil and where' );    ## no critic (RegularExpressions::ProhibitComplexRegexes)

    $r = install(
        args         => [qw{dzil /bogus/checkout}],
        capture      => { "$PERL/bin/dzil authordeps" => ["Dist::Zilla::Plugin::Git\n"], "$PERL/bin/dzil listdeps" => ["Moo\n"] },
        capture_exit => { "$PERL/bin/dzil authordeps" => 2 },
    );
    is( $r->{rc}, 2, 'authordeps failing fails it too' );
    is_deeply( [ map { $_->[2] } @{ $r->{ran} } ], ['authordeps'], 'before installing what it printed, or asking listdeps' );
};

subtest 'pin: the version pkg-config reports, asked when it runs' => sub {
    my $r = install( args => [qw{pin libvirt Sys::Virt}], capture => { 'pkg-config --modversion' => ["10.0.0\n"] } );
    is_deeply( $r->{ran}[-1], [ undef, $CPANM, 'Sys::Virt@10.0.0' ], 'the module at that version' );

    $r = install( args => [qw{pin libvirt Sys::Virt}] );
    is( $r->{rc}, 1, 'pkg-config knowing nothing is a failure' );
    like( $r->{err}, qr/pkg-config[ ]knows[ ]no[ ]libvirt/, 'saying so, rather than installing the newest' );

    $r = install( args => [qw{pin libvirt Sys::Virt}], capture => { 'pkg-config --modversion' => ["10.0.0\n"] }, capture_exit => { 'pkg-config --modversion' => 1 } );
    is( $r->{rc},                                            1, 'and so is pkg-config failing, whatever it printed' );
    is( scalar( grep { $_->[1] eq $CPANM } @{ $r->{ran} } ), 0, 'with nothing pinned' );
};

subtest 'test: the prove of that perl, in the checkout' => sub {
    my $r = install( args => [qw{test /bogus/checkout}] );
    is( $r->{rc}, 0, 'it succeeds' );
    is_deeply( $r->{ran}, [ [ '/bogus/checkout', "$PERL/bin/prove", qw{-lvm t} ] ], 'with lib/ on the path, so a checkout that is not built still finds itself' );

    $r = install( args => [qw{test /bogus/checkout}], fails => qr{/prove\b} );
    is( $r->{rc}, 1, 'and a suite that fails is the exit code' );
};

subtest 'exit_code: what a child exit status says, the way a shell says it' => sub {
    is( Trog::Script::CpanInstall::exit_code(0),        0,   'success' );
    is( Trog::Script::CpanInstall::exit_code( 2 << 8 ), 2,   'the code it exited with' );
    is( Trog::Script::CpanInstall::exit_code(-1),       127, 'a command that never ran' );
    is( Trog::Script::CpanInstall::exit_code(9),        137, 'a command killed by a signal, rather than a success' );
};

subtest 'which installer: cpm for what the mirror index names, cpanm for what it cannot' => sub {
    my $r = install( args => [qw{--notest install Moo}] );
    is_deeply( $r->{ran}, [ [ undef, @CPM, 'Moo' ] ], 'a module by name is whatever the mirror index names, through cpm' );

    $r = install( args => [ qw{--notest install}, 'Moo~>= 2.004' ] );
    is_deeply( $r->{ran}, [ [ undef, @CPM, 'Moo~>= 2.004' ] ], 'and so is one the newest release satisfies' );

    foreach my $spec ( 'Sys::Virt@10.0.0', 'Moo~== 2.004', 'Moo~!= 2.004', 'Moo~< 3', 'Moo~>= 2, <= 3' ) {
        $r = install( args => [ qw{--notest install}, $spec ] );
        is_deeply( $r->{ran}, [ [ undef, $CPANM, '--notest', $spec ] ], "but $spec can want a release the index does not list, so cpanm resolves it" );
    }

    $r = install( args => [qw{--notest pin libvirt Sys::Virt}], capture => { 'pkg-config --modversion' => ["10.0.0\n"] } );
    is_deeply( $r->{ran}[-1], [ undef, $CPANM, qw{--notest Sys::Virt@10.0.0} ], 'as a pin always does' );
};

subtest 'a failed install is the exit code' => sub {
    my $r = install( args => [qw{--notest install Dist::Zilla}], fails => qr/cpm|cpanm/ );
    is( $r->{rc}, 1, 'what cpanm said, after cpm failed as well' );

    $r = install( args => [ qw{--notest install Moo}, 'Sys::Virt@10.0.0' ], fails => qr/cpanm/ );
    is( $r->{rc}, 1, 'and what cpanm said' );
    is_deeply( [ map { $_->[1] } @{ $r->{ran} } ], [$CPANM], 'before cpm installs anything that could build against the wrong version' );
};

subtest 'where cpm fails, cpanm tries the same, and installs each distribution as it goes' => sub {
    my $r = install( args => [qw{--notest install Dist::Zilla}], fails => qr{/cpm[ ]} );
    is( $r->{rc}, 0, 'cpanm succeeding is success' );
    is_deeply( $r->{ran}, [ [ undef, @CPM, 'Dist::Zilla' ], [ undef, $CPANM, qw{--notest --mirror-only Dist::Zilla} ] ], 'with the same specs, from the mirror index' );

    $r = install( args => [qw{--notest installdeps /bogus/app}], fails => qr{/cpm[ ]} );
    is_deeply(
        $r->{ran}[-1],
        [ '/bogus/app', $CPANM, qw{--notest --mirror-only --installdeps .} ],
        'and installdeps asks cpanm in the same directory'
    );

    $r = install( args => [qw{--notest install Dist::Zilla}] );
    is( scalar @{ $r->{ran} }, 1, 'and cpm succeeding needs no cpanm' );
};

subtest 'cpm is installed with cpanm, the first time it is needed' => sub {
    unlink "$PERL/bin/cpm" or die "could not remove the fake cpm: $!";

    my $r = install( args => [qw{--notest install Moo}] );
    is_deeply( $r->{ran}, [ [ undef, $CPANM, qw{--notest --mirror-only App::cpm} ], [ undef, @CPM, 'Moo' ] ], 'cpanm installs App::cpm, and then cpm installs the rest' );

    $r = install( args => [qw{--notest install Moo}], fails => qr/App::cpm/ );
    is( $r->{rc},              1, 'and if cpm does not install, nothing else is tried' );
    is( scalar @{ $r->{ran} }, 1, 'with no cpm run after it' );

    open( my $fh, '>', "$PERL/bin/cpm" ) or die $!;
    close($fh)                           or die "Could not close $PERL/bin/cpm: $!";
    chmod( 0755, "$PERL/bin/cpm" );
};

subtest 'the perl that was built is the one installed into' => sub {
    make_path("$PERL_ROOT/perl5.40.0/bin");

    # With no link, the newest, which is the answer on a guest with one perl.
    my $r = install( args => [qw{--notest install Moo}] );
    is( $r->{ran}[0][1], "$PERL/bin/perl", 'not whichever was built first' );

    # With one, what it points at, whichever of them that is.  A guest rebuilt
    # with another version has both, and only the configuration knows which one
    # the modules belong in.
    symlink 'perl5.40.0', "$PERL_ROOT/current" or die "could not link: $!";
    my $older = install( args => [qw{--notest install Moo}] );
    is( $older->{ran}[0][1],            "$PERL_ROOT/current/bin/cpanm", 'the cpanm of the perl that /opt/perl5/current names, which installs its cpm' );
    is( $older->{ran}[-1][1],           "$PERL_ROOT/current/bin/perl",  'and then that perl runs it' );
    is( readlink("$PERL_ROOT/current"), 'perl5.40.0',                   'which here is the older of the two, and not the newest' );
    unlink "$PERL_ROOT/current";

    rmdir "$PERL_ROOT/perl5.40.0/bin";
    rmdir "$PERL_ROOT/perl5.40.0";
};

subtest 'it has to be told what to do, and have a perl to do it in' => sub {
    is( install( args => [] )->{rc},                 2, 'no verb is a usage error' );
    is( install( args => [qw{frobnicate x}] )->{rc}, 2, 'and so is one it does not know' );

    my $r = install( args => [qw{install Moo}], perl_root => tempdir( CLEANUP => 1 ) );
    like( $r->{err}, qr/nothing[ ]is[ ]built[ ]under/, 'and no built perl is said plainly, naming where it looked' );
};

done_testing();
