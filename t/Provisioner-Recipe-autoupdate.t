#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-autoupdate.t - the reboot check of autoupdate: the switch, and the edges of the reboot window

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use File::Temp       qw{tempdir};
use File::Path       qw{make_path};
use IPC::Run3();
use File::Slurper::Temp();

use FindBin::libs;

use Provisioner::Cookbook();

my $dir = tempdir( CLEANUP => 1 );

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => $dir,
    distro          => 'ubuntu',
    target_packager => 'deb',
);

my %G = (
    domain      => 'up.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'someadmin',
);

# A file that a test runs, which the script under test finds by name.
sub executable {
    my ( $file, $text ) = @_;
    File::Slurper::Temp::write_text( $file, $text );
    chmod 0755, $file or die "$file: $!";
    return;
}

# The check asks date for the hour, so this one stands in for it, first on the
# PATH, and answers with the hour in FAKE_HOUR.
make_path("$dir/bin");
executable( "$dir/bin/date", qq{#!/bin/sh\necho "\$FAKE_HOUR"\n} );

my $switch = "$dir/noautorestart";

# What the check renders to for %args says at $hour: its exit status and reason.
sub ask {
    my ( $hour, %args ) = @_;
    my $recipe = Provisioner::Cookbook->load( 'autoupdate', distro => 'ubuntu' )->new(%PROV);
    my $check  = "$dir/check";
    executable( $check, $recipe->render_file( 'files/autoupdate.reboot-check.tt', %G, autorestart => $switch, %args ) );

    local $ENV{PATH}      = "$dir/bin:$ENV{PATH}";
    local $ENV{FAKE_HOUR} = $hour;
    IPC::Run3::run3( [$check], \undef, \my $out, \my $err );
    die "the check wrote to stderr: $err" if $err ne '';
    my $status = $? >> 8;
    chomp $out;
    return ( $status, $out );
}

subtest 'the switch' => sub {
    is_deeply( [ ask(12) ], [ 0, '' ], 'without the switch, it says yes' );

    File::Slurper::Temp::write_text( $switch, '' );
    is_deeply( [ ask(12) ], [ 1, "held by $switch" ], 'with it, it holds the reboot and names the switch' );
    unlink $switch;
};

subtest 'a window within one day' => sub {
    my %w = ( reboot_window => { from => 2, to => 5 } );
    is_deeply( [ ask( 1, %w ) ], [ 1, 'outside the reboot window 02:00-05:00' ], 'the hour before it is outside' );
    is( ( ask( 2, %w ) )[0], 0, 'the hour from is inside' );
    is( ( ask( 4, %w ) )[0], 0, 'the hour before to is inside' );
    is( ( ask( 5, %w ) )[0], 1, 'the hour to is outside' );
};

subtest 'a window past midnight' => sub {
    my %w = ( reboot_window => { from => 22, to => 4 } );
    is( ( ask( 21, %w ) )[0], 1, 'the hour before from is outside' );
    is( ( ask( 22, %w ) )[0], 0, 'the hour from is inside' );
    is( ( ask( 0,  %w ) )[0], 0, 'midnight is inside' );
    is( ( ask( 3,  %w ) )[0], 0, 'the hour before to is inside' );
    is_deeply( [ ask( 4, %w ) ], [ 1, 'outside the reboot window 22:00-04:00' ], 'the hour to is outside' );
};

subtest 'a window whose ends are equal' => sub {
    my %w = ( reboot_window => { from => 3, to => 3 } );
    is( ( ask( $_, %w ) )[0], 0, "hour $_ is inside" ) for 0, 3, 23;
};

subtest 'the switch and the window together' => sub {
    File::Slurper::Temp::write_text( $switch, '' );
    is_deeply(
        [ ask( 12, reboot_window => { from => 2, to => 5 } ) ],
        [ 1, "held by $switch, outside the reboot window 02:00-05:00" ],
        'the reason names both, on the one line that the log takes',
    );
    unlink $switch;
};

had_no_warnings();

done_testing();
