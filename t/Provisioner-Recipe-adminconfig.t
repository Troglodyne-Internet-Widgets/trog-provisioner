#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-adminconfig.t - the dotfiles of the admin, and the modes
that ssh needs on them

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Path();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin::libs;

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);

sub recipe { return Provisioner::Cookbook->load( 'adminconfig', distro => 'ubuntu' )->new(%PROV) }

# The global fragment, run in a scratch home with an rsync that copies $skel,
# which is what the skel module of the machine that guests fetch from gives.
sub run_fragment {
    my ( $home, $skel ) = @_;
    my $fragment = recipe()->render_global(
        domain        => 'admin.test.test',
        install_dir   => '/opt/domains',
        script_dir    => '/root/bin',
        admin_user    => scalar getpwuid($<),
        admin_home    => $home,
        skel          => $skel,
        transfer_user => 'transfer',
        transfer_ip   => '192.0.2.1',
        transfer_port => 22,
    );

    my $bin = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$bin/rsync", qq{#!/bin/sh\nfor last; do :; done\ncp -a '$skel/.' "\$last"\n} );
    chmod 0755, "$bin/rsync";

    my @lines = grep { m/\S/ } split m/\n/, $fragment;
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    IPC::Run3::run3( [ '/bin/sh', '-c', join "\n", map { "$_ || exit 1" } @lines ], \undef, \my $said, \my $errors );
    return ( $? >> 8, $errors );
}

subtest 'a config and a key from skel end closed to the group, as ssh needs them' => sub {
    my $skel = tempdir( CLEANUP => 1 );
    File::Path::make_path("$skel/.ssh");
    File::Slurper::Temp::write_text( "$skel/.ssh/config",         "Host *\n" );
    File::Slurper::Temp::write_text( "$skel/.ssh/id_ed25519",     "not a key\n" );
    File::Slurper::Temp::write_text( "$skel/.ssh/id_ed25519.pub", "not a key either\n" );
    File::Slurper::Temp::write_text( "$skel/.bashrc",             "# nothing\n" );
    chmod 0755, "$skel/.ssh", "$skel/.ssh/config";
    chmod 0644, "$skel/.ssh/id_ed25519", "$skel/.ssh/id_ed25519.pub", "$skel/.bashrc";

    my $home = tempdir( CLEANUP => 1 );
    my ( $status, $err ) = run_fragment( $home, $skel );
    is( $status, 0, 'the fragment runs' ) or diag $err;

    my $mode = sub { my ($path) = @_; return sprintf '%04o', ( stat "$home/$path" )[2] & oct 7777 };
    is( $mode->('.ssh/config'),     '0700', 'the config is closed to the group and to others' );
    is( $mode->('.ssh/id_ed25519'), '0600', 'and so is the private key' );
    is( $mode->('.ssh'),            '0700', 'and the directory that holds them' );
    is( $mode->('.bashrc'),         '0644', 'and a dotfile outside .ssh keeps its mode' );
};

subtest 'a skel with no .ssh is not an error' => sub {
    my $skel = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$skel/.bashrc", "# nothing\n" );
    my ( $status, $err ) = run_fragment( tempdir( CLEANUP => 1 ), $skel );
    is( $status, 0, 'the fragment runs' ) or diag $err;
};

Test::NoWarnings::had_no_warnings();

done_testing();
