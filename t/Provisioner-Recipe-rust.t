#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-rust.t - which toolchain the rust recipe asks rustup for

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);

my %G = (
    domain      => 'build.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'someadmin',
    user        => 'builder',
);

sub recipe { return Provisioner::Cookbook->load( 'rust', distro => 'ubuntu' )->new(%PROV) }

subtest 'the toolchain it installs' => sub {
    my %got = recipe()->validated(%G);
    is( $got{toolchain}, 'stable', 'stable, when the configuration does not say' );

    %got = recipe()->validated( %G, toolchain => '1.83.0' );
    is( $got{toolchain}, '1.83.0', 'and the one it names, when it does' );
};

# The package is the installer.  A guest with rustup and no toolchain has
# nothing to compile with, and nothing says so until something tries.
subtest 'the fragment asks rustup for a toolchain' => sub {
    my $said = recipe()->render_global(%G);
    like( $said, qr/rustup[ ]default[ ]'stable'/, 'by default, for stable' );

    my $pinned = Provisioner::Cookbook->load( 'rust', distro => 'ubuntu' )->new(%PROV)->render_global( %G, toolchain => '1.83.0' );
    like( $pinned, qr/rustup[ ]default[ ]'1\.83\.0'/, 'and for a version that was pinned' );

    # A toolchain belongs to the machine rather than to a domain, so there is
    # nothing per domain to run.
    ok( !recipe()->has_template(), 'and there is no per-domain half' );
};

subtest 'what it needs installed, and where it fetches from' => sub {
    my @deps = recipe()->deps();
    ok( ( grep { $_ eq 'rustup' } @deps ), 'rustup comes from the distribution' );

    # rustc calls cc to link every binary it builds, and depends on neither.
    ok( ( grep { $_ eq 'build-essential' } @deps ), 'and the C toolchain it links with' );

    is_deeply( [ recipe()->fetch_hosts() ], ['static.rust-lang.org'], 'the toolchain comes from there, which no template says' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
