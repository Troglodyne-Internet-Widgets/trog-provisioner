#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-go.t - which release of Go the go recipe installs, and how it checks the archive

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

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
    admin_user  => 'doge',
    user        => 'builder',
);

my $SHA = 'a' x 64;

sub recipe { return Provisioner::Cookbook->load( 'go', distro => 'ubuntu' )->new(%PROV) }

subtest 'the release it installs' => sub {
    my %got = recipe()->validated(%G);
    like( $got{version}, qr/\A\d+[.]\d+[.]\d+\z/,    'a pinned release, when the configuration does not say' );
    like( $got{sha256},  qr/\A[[:digit:]a-f]{64}\z/, 'with the SHA-256 of its archive' );

    %got = recipe()->validated( %G, version => '1.26.11', sha256 => $SHA );
    is_deeply( [ @got{qw{version sha256}} ], [ '1.26.11', $SHA ], 'and the one it names, when it does' );

    ok( exception { recipe()->validated( %G, version => 'go1.26.11' ) }, 'a version with the go in front is refused, because the URL adds it' );
    ok( exception { recipe()->validated( %G, sha256  => 'A' x 64 ) },    'and so is a SHA-256 that sha256sum would never print' );
};

subtest 'the fragment checks the archive before it replaces the toolchain' => sub {
    my $said = recipe()->render_global( %G, version => '1.26.11', sha256 => $SHA );
    my ($line) = $said =~ m{^(if\ .*?^fi)$}ms;
    ok( $line, 'one shell line installs it' ) or diag $said;
    like( $line, qr{'https://go[.]dev/dl/go1[.]26[.]11[.]linux-amd64[.]tar[.]gz'}, 'from the archive of that release' );
    ok( index( $line, "echo '$SHA  go1.26.11.linux-amd64.tar.gz' | sha256sum -c" ) >= 0, 'whose SHA-256 is checked' );
    ok( index( $line, 'sha256sum' ) < index( $line, 'rm -rf /usr/local/go' ),            'before the toolchain there goes' );
    ok( !recipe()->has_template(), 'and there is no per-domain half, because a toolchain belongs to the machine' );
};

subtest 'where it fetches from' => sub {
    is_deeply( [ recipe()->fetch_hosts() ], [qw{go.dev dl.google.com}], 'go.dev, and the host it redirects the download to' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
