#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Provisioner-Recipe-perl.t - the perl recipe: what the recipes depending on it
hand it to install from CPAN, and how its own target installs it

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use Hash::Merge();
use IPC::Run3();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();

my $DOMAIN  = 'perl.test.test';
my $INSTALL = '/opt/domains';
my %GUEST   = (
    domain      => $DOMAIN,
    install_dir => $INSTALL,
    script_dir  => '/root/bin',
    admin_user  => 'admin',
    admin_email => 'admin@test.test',
    admin_key   => 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtheadminkey admin',
    gateway     => '192.168.1.254',
    main_ip     => '192.168.1.50',
);

sub recipe {
    my ($name) = @_;
    return Provisioner::Cookbook->load( $name, distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

sub rendered {
    my (%opts) = @_;
    return recipe('perl')->render( %GUEST, %opts );
}

# The cpan_install lines of a fragment, each as the words it hands over.
sub installs {
    my ($fragment) = @_;
    return map { [m/'([^']*)'/g] } grep { m{/cpan_install\b} } split( "\n", $fragment );
}

subtest 'every step it is handed is installed in its own target, in order, after the perl' => sub {
    my $out = rendered(
        cpan_deps => [
            { install     => [ 'Moo', 'Sys::Virt@10.0.0', 'Moo~>= 2.004' ] },
            { installdeps => '/bogus/app' },
            { dzil        => '/bogus/checkout' },
            { pin         => { module => 'Sys::Virt', pkgconfig => 'libvirt' } },
            { install     => ['Dist::Zilla'], link => ['dzil'] },
        ]
    );

    my @got = installs($out);
    is_deeply( shift @got, [qw{install Test2 Devel::NYTProf Starman Perl::Critic Perl::Tidy}], 'the baseline first, whatever else was handed over' );
    is_deeply(
        [@got],
        [
            [ qw{install Moo Sys::Virt@10.0.0}, 'Moo~>= 2.004' ],
            [ 'installdeps',                    '/bogus/app' ],
            [ 'dzil',                           '/bogus/checkout' ],
            [qw{pin libvirt Sys::Virt}],
            [qw{--link dzil install Dist::Zilla}],
        ],
        'one cpan_install each, in the order handed over, every word quoted'
    );
    ok( index( $out, 'build_latest_perl.sh' ) < index( $out, 'cpan_install' ), 'after the perl they go into is built' );
    ok( index( $out, 'cpan_install' ) < index( $out, 'link_perl_tools' ),      'and the tools are linked after all of them, rather than before' );
    unlike( $out, qr/queue_postrun_task/, 'there and then, rather than queued behind what the dependants queued' );

    is_deeply( [ installs( rendered() ) ], [ [qw{install Test2 Devel::NYTProf Starman Perl::Critic Perl::Tidy}] ], 'nothing handed over is the baseline alone' );

    # A schema default is filled in only when the key is absent, and cpan_deps
    # is present on any guest whose recipes hand something over -- which is most
    # of them.  So the baseline is a boolean, not a defaulted list.
    my @bare = installs( rendered( baseline => 0, cpan_deps => [ { install => ['Moo'] } ] ) );
    is_deeply( \@bare, [ [qw{install Moo}] ], 'and baseline off is what was handed over alone' );
};

subtest 'test suites are skipped unless cpan_notest is off' => sub {
    my @steps = ( { install => ['Moo'] } );

    like( rendered( cpan_deps   => \@steps ),                   qr{^/root/bin/cpan_install --notest 'install' 'Moo'$}m, 'skipped when nothing says, which is the default' );
    like( rendered( cpan_deps   => \@steps, cpan_notest => 0 ), qr{^/root/bin/cpan_install 'install' 'Moo'$}m,          'run when it is off' );
    like( rendered( cpan_notest => 0 ),                         qr{^\S+/cpan_install 'install' 'Test2'}m,               'for the baseline too' );
};

subtest 'a step that cannot be one is refused by the schema' => sub {
    foreach my $case (
        [ { install     => ['Moo'], dzil => '/bogus' }, qr/oneOf rules 0, 2 match/,           'two verbs' ],
        [ { link        => ['dzil'] },                  qr/Missing property/,                 'none' ],
        [ { install     => ['Moo'], notest => 0 },      qr/Properties not allowed: notest/,   'a key no step has' ],
        [ { pin         => { module => 'Sys::Virt' } }, qr{/pin/pkgconfig: Missing property}, 'a pin without the package it pins to' ],
        [ { install     => [] },                        qr/Not enough items/,                 'an install of nothing' ],
        [ { install     => ["O'Reilly"] },              qr/does not match/,                   'a quote' ],
        [ { install     => ['Moo$HOME'] },              qr/does not match/,                   'a dollar, which make would eat' ],
        [ { installdeps => '/bogus`id`' },              qr/does not match/,                   'a backtick' ],
        [ { dzil        => "/bogus\n/other" },          qr/does not match/,                   'a newline' ],
        [ { installdeps => '/bogus\\other' },           qr/does not match/,                   'a backslash' ],
    ) {
        my ( $step, $error, $what ) = @$case;
        like( exception { rendered( cpan_deps => [$step] ) }, qr{/cpan_deps/0[^\n]*$error}, $what );
    }

    # Measured: a pattern that lost a backslash on the way into its string
    # forbade the letter n, and every path under /opt/domains with it.
    is( exception { rendered( cpan_deps => [ { installdeps => '/opt/domains/fun.test/nothing' } ] ) }, undef, 'while an ordinary path, n and all, is fine' );
};

subtest 'the words reach cpan_install intact, through the shell that runs the line' => sub {
    my $bin = tempdir( CLEANUP => 1 );
    open( my $c, '>', "$bin/cpan_install" ) or die $!;
    print {$c} qq{#!/bin/bash\nprintf '%s\\n' "\$\@" > $bin/out\n};
    close $c;
    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    chmod( 0755, "$bin/cpan_install" );
    ## use critic

    # baseline off, so the line taken below is the one with the awkward words in
    # it rather than the toolchain the recipe installs first.
    my ($line) = grep { m{/cpan_install\b} } split( "\n", rendered( script_dir => $bin, baseline => 0, cpan_deps => [ { install => [ 'Moo~>= 2.004', 'Sys::Virt@10.0.0' ] } ] ) );

    # dash, which is what make runs a recipe line under.
    IPC::Run3::run3( [ '/bin/sh', '-c', $line ], \undef, \my $out, \my $err );
    is( $?, 0, 'dash runs the line' ) or diag $err;

    open( my $got, '<', "$bin/out" ) or die $!;
    chomp( my @args = <$got> );
    is_deeply( \@args, [ '--notest', 'install', 'Moo~>= 2.004', 'Sys::Virt@10.0.0' ], 'one argument per word, the space and the > included' );
};

subtest 'what each recipe depending on it hands over, it takes, and the merge keeps all of it' => sub {
    my $merged = {};
    foreach my $name (qw{tcms tpsgi trogrunner}) {
        my %required = recipe($name)->required_recipes(%GUEST);
        is( ref $required{perl}, 'CODE', "$name depends on perl" ) or next;

        # As bin/new_config asks: the dependency is handed the guest and the
        # dependant's configuration, and what comes back is merged in.
        my %handed = $required{perl}->(%GUEST);
        ok( scalar @{ $handed{cpan_deps} // [] }, "$name hands it something to install" );
        $merged = Hash::Merge::merge( $merged, \%handed );
    }

    # baseline off: what is asserted here is what the dependants handed over,
    # which the recipe installs after its own toolchain.
    my @installs = installs( rendered( %$merged, baseline => 0 ) );
    is_deeply( $installs[0], [ 'installdeps', "$INSTALL/$DOMAIN/tCMS" ], 'tcms: what its checkout needs, first, as it was merged first' );
    ok( ( grep { $_->[0] eq 'installdeps' && $_->[1] eq "$INSTALL/$DOMAIN" } @installs ), 'tpsgi: what the domain checkout needs' );
    ok( ( grep { $_->[-1] eq 'Dist::Zilla' } @installs ),                                 'trogrunner: Dist::Zilla, among its own' );
    is( scalar @installs, 5, 'all of them, the merge dropping none' );
};

subtest 'a dependant told no install_dir dies, rather than installing from somewhere else' => sub {
    my %required = recipe('tcms')->required_recipes();
    like( exception { $required{perl}->( domain => $DOMAIN ) }, qr/defined, positive-length/, 'tcms' );

    %required = recipe('tpsgi')->required_recipes();
    like( exception { $required{perl}->( install_dir => $INSTALL ) }, qr/defined, positive-length/, 'tpsgi' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
