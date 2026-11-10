#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/mount_virtiofs.t - scripts/mount_virtiofs: the share is mounted when it
exits 0, and the build stops when it is not

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/mount_virtiofs";

# The tools of systemd and e2fsprogs, first on the PATH.  Each logs its command
# line.  mountpoint says a share is mounted once a fake start has mounted it,
# or when FAKE_MOUNTED is set.  A start exits FAKE_START, and mounts the share
# when it exits 0, unless FAKE_NOMOUNT is set.
my %FAKE = (
    'systemd-escape' => <<'SH',
#!/bin/sh
echo "bogus-share.${2#--suffix=}"
SH
    mountpoint => <<'SH',
#!/bin/sh
echo "mountpoint $*" >> "$FAKE_DIR/log"
[ -e "$FAKE_DIR/mounted" ]
SH
    chattr => <<'SH',
#!/bin/sh
echo "chattr $*" >> "$FAKE_DIR/log"
SH
    systemctl => <<'SH',
#!/bin/sh
echo "systemctl $*" >> "$FAKE_DIR/log"
case "$1" in
start)
    [ "${FAKE_START:-0}" = 0 ] && [ -z "${FAKE_NOMOUNT:-}" ] && touch "$FAKE_DIR/mounted"
    exit "${FAKE_START:-0}" ;;
status) echo "bogus status of $*" ;;
esac
SH
);

# One run in a directory of its own.  Returns what it exited with, its stderr,
# the commands that the fakes logged, other than mountpoint, and the
# directory.
sub mount_virtiofs {
    my ( $key, %env ) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/$_" or die "Cannot make $dir/$_: $!" for qw{bin units};
    foreach my $tool ( keys %FAKE ) {
        File::Slurper::Temp::write_text( "$dir/bin/$tool", $FAKE{$tool} );
        chmod 0755, "$dir/bin/$tool" or die "Cannot make the fake $tool executable: $!";
    }
    File::Slurper::Temp::write_text( "$dir/devices.map",                 "/bogus/share2=vdc\n/bogus/share=vdb\n" );
    File::Slurper::Temp::write_text( "$dir/units/bogus-share.automount", "[Automount]\n" );
    if ( $env{FAKE_MOUNTED} ) {
        File::Slurper::Temp::write_text( "$dir/mounted", q{} );
    }
    if ( my $file = delete $env{FAKE_LEFTOVER} ) {
        mkdir "$dir/mnt" or die "Cannot make $dir/mnt: $!";
        File::Slurper::Temp::write_text( "$dir/mnt/$file", q{} );
    }

    # scripts/device_for reads the map that DEVICES_MAP names.
    local %ENV = (
        %ENV,
        PATH        => "$dir/bin:$ENV{PATH}",
        FAKE_DIR    => $dir,
        DEVICES_MAP => "$dir/devices.map",
        UNIT_DIR    => "$dir/units",
        %env,
    );
    IPC::Run3::run3( [ $script, $key, "$dir/mnt", 'virtiofs' ], \undef, \my $out, \my $err );
    my $rc  = $? >> 8;
    my $log = -e "$dir/log" ? File::Slurper::read_text("$dir/log") : q{};
    return ( $rc, $err, [ grep { !m/\Amountpoint\ / } split m/\n/, $log ], $dir );
}

subtest 'a share that mounts' => sub {
    my ( $rc, $err, $ran, $dir ) = mount_virtiofs('/bogus/share');
    is( $rc, 0, 'it exits 0' ) or diag $err;
    is_deeply(
        $ran,
        [ "chattr +i $dir/mnt", 'systemctl daemon-reload', 'systemctl reenable bogus-share.mount', 'systemctl start bogus-share.mount' ],
        'it makes the empty mountpoint immutable before it mounts the share, and enables the unit for the next boot'
    );
    ok( -d "$dir/mnt", 'it makes the mountpoint' );

    is( File::Slurper::read_text("$dir/units/bogus-share.mount"), <<"UNIT", 'the unit mounts the device of the key, and local-fs.target wants it' );
[Unit]
Description=virtiofs share /bogus/share from the hypervisor

[Mount]
What=vdb
Where=$dir/mnt
Type=virtiofs

[Install]
WantedBy=local-fs.target
UNIT
    ok( !-e "$dir/units/bogus-share.automount", 'it removes the automount unit that older versions wrote' );
};

subtest 'a share that is mounted already' => sub {
    my ( $rc, $err, $ran ) = mount_virtiofs( '/bogus/share', FAKE_MOUNTED => 1 );
    is( $rc,        0,                                   'it exits 0' ) or diag $err;
    is( $ran->[0],  'systemctl daemon-reload',           'and leaves the mountpoint alone, because what chattr sees there is the share' );
    is( $ran->[-1], 'systemctl start bogus-share.mount', 'and starts the unit, which is active already' );
};

subtest 'a key that is only the start of a key in the map' => sub {
    my ( $rc, $err, $ran, $dir ) = mount_virtiofs('/bogus/shar');
    is( $rc, 1, 'it exits 1' );
    like( $err, qr{no\ device\ for\ '/bogus/shar'}, 'and says that the map has no device for the key' );
    is_deeply( $ran, ["chattr +i $dir/mnt"], 'and leaves the mountpoint immutable, with no unit for it' );
};

subtest 'a share that does not mount' => sub {
    my ( $rc, $err, $ran, $dir ) = mount_virtiofs( '/bogus/share', FAKE_START => 1 );
    is( $rc, 1, 'a unit that fails to start exits 1' );
    my $what = qr{could\ not\ mount\ /bogus/share\ from\ the\ hypervisor};
    like( $err, qr{$what\ at\ \S+/mnt},        'and says what it could not mount where' );
    like( $err, qr{bogus\ status\ of\ status}, 'with the status of the unit' );
    is( $ran->[0], "chattr +i $dir/mnt", 'the mountpoint it leaves is immutable' );

    ($rc) = mount_virtiofs( '/bogus/share', FAKE_NOMOUNT => 1 );
    is( $rc, 1, 'so does a unit that starts, with nothing mounted at the mountpoint' );
};

subtest 'a mountpoint that holds files on the root disk' => sub {
    my ( $rc, $err, $ran ) = mount_virtiofs( '/bogus/share', FAKE_LEFTOVER => 'bogus-file' );
    is( $rc, 1, 'it exits 1' );
    like( $err, qr{holds\ files\ on\ the\ root\ disk}, 'and says that the share would hide them' );
    is_deeply( $ran, [], 'and mounts nothing over them' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
