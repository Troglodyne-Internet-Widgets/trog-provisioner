#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/setup_chroot_mount.t - scripts/setup_chroot_mount: the bind mount is added to F</etc/fstab> once, and the rest of the file is left as it was

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use File::Slurper();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/setup_chroot_mount";

# Out of order and commented, the way an fstab is.
my $FSTAB = <<'FSTAB';
# /etc/fstab: static file system information.
UUID=bogus-root / ext4 errors=remount-ro 0 1
/swap.img none swap sw 0 0 # the installer made this
UUID=bogus-boot /boot ext4 defaults 0 2
FSTAB

# A mount and a mountpoint of our own, first on the PATH: nothing is mounted,
# and a mount is recorded rather than made.
my $dir = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$dir/mountpoint", "#!/bin/sh\nexit 1\n" );
File::Slurper::Temp::write_text( "$dir/mount",      qq{#!/bin/sh\necho "\$*" >> "$dir/mounted"\n} );
chmod( 0755, "$dir/mountpoint", "$dir/mount" ) or die "Cannot make the fake mount tools executable: $!";

File::Slurper::Temp::write_text( "$dir/fstab", $FSTAB );
my $target = "$dir/bogus-data";
my $link   = "$dir/bogus-chroot/data";
my $line   = "$target $link none defaults,bind 0 0\n";

sub setup {
    local $ENV{PATH}  = "$dir:$ENV{PATH}";
    local $ENV{FSTAB} = "$dir/fstab";
    IPC::Run3::run3( [ $script, $target, $link ], \undef, \my $out, \my $err );
    is( $? >> 8, 0, 'setup_chroot_mount exits clean' ) or diag $err;
    return;
}

setup();
is( File::Slurper::read_text("$dir/fstab"), $FSTAB . $line, 'the bind mount is appended, and every other line is as it was' );
ok( -d $link, 'the mountpoint is made' );
is( File::Slurper::read_text("$dir/mounted"), "$link\n", 'and mounted, by its mountpoint' );

setup();
is( File::Slurper::read_text("$dir/fstab"), $FSTAB . $line, 'a second run adds nothing' );

Test::NoWarnings::had_no_warnings();
done_testing();
