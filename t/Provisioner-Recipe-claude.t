#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-claude.t - what the claude recipe installs, and in what order

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
    domain      => 'agent.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'someadmin',
    user        => 'agent',
    modules     => [],
);

sub recipe { return Provisioner::Cookbook->load( 'claude', distro => 'ubuntu' )->new(%PROV) }

subtest 'the rtk release it installs' => sub {
    my %got = recipe()->validated(%G);
    like( $got{rtk_version}, qr/\Av\d+\.\d+\.\d+\z/, 'a tag by default' );

    my $said = recipe()->render( %G, rtk_version => 'v1.2.3' );
    like( $said, qr{releases/download/v1\.2\.3/rtk_1\.2\.3-1_}, 'the .deb of the tag it was given' );

    # dpkg names a version without the v, and the package adds its own -1.  A
    # mismatch here reinstalls on every provision rather than never.
    like( $said, qr/dpkg-query[^\n]*rtk/, 'the check asks dpkg what is installed' );
    like( $said, qr/=[ ]"1\.2\.3-1"/,     'against the version dpkg reports, which carries the package revision' );
};

# rtk edits the settings file rather than writing its own.  Installed before
# the recipe puts that file in place, its hook is overwritten by the next line
# and nothing says so.
subtest 'rtk is registered after the settings are installed' => sub {
    my $said = recipe()->render(%G);

    my ($settings) = $said =~ m/(.*claude\.settings\.json.*)/;
    ok( $settings, 'the settings file is installed' );

    my $mv_at   = index( $said, 'claude.settings.json' );
    my $init_at = index( $said, 'rtk init' );
    ok( $init_at > $mv_at, 'and rtk is registered afterwards' );

    like( $said, qr/rtk[ ]init[ ]-g[ ]--auto-patch/,                  'without questions, which a makefile has nobody to answer' );
    like( $said, qr/HOME='[^']*\/agent\.test\.test'[^\n]*rtk[ ]init/, 'into the home the agent runs out of' );
};

subtest 'where it fetches from, and what the cache keeps' => sub {
    my @hosts = recipe()->fetch_hosts();
    ok( ( grep { $_ eq 'github.com' } @hosts ), 'the release comes from GitHub' );

    my @classes = recipe()->cache_classes();
    ok( ( grep { ( $_->{class} // q{} ) eq 'immutable' } @classes ), 'and a release asset is immutable to the cache' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
