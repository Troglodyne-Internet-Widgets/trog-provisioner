#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

# The script is loaded when the test runs rather than when it compiles, so perl
# sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/cpan_install.t - scripts/cpan_install: each verb a recipe can declare, into
the perl the perl recipe built

=cut

use Test::More;
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
for my $tool (qw{cpanm dzil}) {
    open( my $fh, '>', "$PERL/bin/$tool" ) or die $!;
    close $fh;
    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    chmod( 0755, "$PERL/bin/$tool" );
}
my $CPANM = "$PERL/bin/cpanm";

# One run of cpan_install, with every command it would have run written down
# rather than run.  %capture says what a captured command prints, by its first
# two words.
sub install {
    my (%case) = @_;

    local $Trog::Script::CpanInstall::PERL_ROOT = $case{perl_root} // $PERL_ROOT;

    my @ran;

    # no_auto: it was loaded from its path above, so there is no module file to load.
    my $script = Test::MockModule->new( 'Trog::Script::CpanInstall', no_auto => 1 );
    $script->redefine( run_in     => sub { my ( $dir, @cmd ) = @_; push @ran, [ $dir, @cmd ]; return $case{fails} && $cmd[0] =~ $case{fails} ? 1 : 0 } );
    $script->redefine( capture_in => sub { my ( $dir, @cmd ) = @_; push @ran, [ $dir, @cmd ]; return @{ $case{capture}{"@cmd[0,1]"} // [] } } );

    my ( $out, $err ) = ( q{}, q{} );
    my $rc;
    {
        local *STDOUT;
        local *STDERR;
        open( STDOUT, '>', \$out ) or die $!;
        open( STDERR, '>', \$err ) or die $!;
        $rc = eval { Trog::Script::CpanInstall::main( @{ $case{args} } ) };
        $err .= $@ if $@;
    }
    return { rc => $rc, ran => \@ran, out => $out, err => $err };
}

subtest 'install: into the newest perl the recipe built' => sub {
    my $r = install( args => [ qw{--notest install Moo Sys::Virt@10.0.0}, 'Moo~>= 2.004' ] );

    is( $r->{rc}, 0, 'it succeeds' );
    is_deeply( $r->{ran}, [ [ undef, $CPANM, qw{--notest Moo Sys::Virt@10.0.0}, 'Moo~>= 2.004' ] ], 'that perl cpanm, with a pin and a version requirement each handed on as one word' );
};

subtest 'the test suites run unless told not to' => sub {
    my $r = install( args => [qw{install Moo}] );
    ok( !( grep { defined && $_ eq '--notest' } @{ $r->{ran}[0] } ), 'no --notest unless asked for' );
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

subtest 'a failed install is the exit code' => sub {
    my $r = install( args => [qw{--notest install Dist::Zilla}], fails => qr/cpanm/ );
    is( $r->{rc}, 1, 'what cpanm said' );
};

subtest 'the newest perl is the one installed into' => sub {
    make_path("$PERL_ROOT/perl5.40.0/bin");

    my $r = install( args => [qw{--notest install Moo}] );
    is( $r->{ran}[0][1], $CPANM, 'not whichever was built first' );
    rmdir "$PERL_ROOT/perl5.40.0/bin";
    rmdir "$PERL_ROOT/perl5.40.0";
};

subtest 'it has to be told what to do, and have a perl to do it in' => sub {
    is( install( args => [] )->{rc},                 2, 'no verb is a usage error' );
    is( install( args => [qw{frobnicate x}] )->{rc}, 2, 'and so is one it does not know' );

    my $r = install( args => [qw{install Moo}], perl_root => tempdir( CLEANUP => 1 ) );
    like( $r->{err}, qr/nothing is built under/, 'and no built perl is said plainly, naming where it looked' );
};

done_testing();
