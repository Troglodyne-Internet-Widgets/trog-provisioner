#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/check_sshd_config.t - scripts/check_sshd_config: sshd -t, with the directory
that it needs

=cut

use FindBin;
use FindBin::libs;
use Test::More;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use IPC::Run3();

my $script = "$FindBin::Bin/../scripts/check_sshd_config";
my $dir    = tempdir( CLEANUP => 1 );

# An sshd that says whether its directory is there and what it was asked, and
# exits with the status that the test gives it.
mkdir "$dir/bin" or die "mkdir: $!";
File::Slurper::Temp::write_text( "$dir/bin/sshd", qq{#!/bin/sh\n[ -d "\$SSHD_PRIVSEP_DIR" ] && echo there\necho "\$@"\nexit \${SSHD_EXIT:-0}\n} );
chmod 0755, "$dir/bin/sshd";

local $ENV{PATH}             = "$dir/bin:$ENV{PATH}";
local $ENV{SSHD_PRIVSEP_DIR} = "$dir/run/sshd";

IPC::Run3::run3( [$script], \undef, \my $out, \undef );
is( $?,                                     0,             'a configuration that sshd accepts exits 0' );
is( $out,                                   "there\n-t\n", 'and sshd -t runs with the directory already there' );
is( ( stat "$dir/run/sshd" )[2] & oct 7777, oct 755,       'which is 0755, as ssh.service makes it' );

IPC::Run3::run3( [ $script, '-f', '/bogus/sshd_config' ], \undef, \$out, \undef );
is( $out, "there\n-t -f /bogus/sshd_config\n", 'it passes on what it is given' );

local $ENV{SSHD_EXIT} = 255;
IPC::Run3::run3( [$script], \undef, \undef, \undef );
is( $? >> 8, 255, 'and a configuration that sshd refuses fails the line, so make stops the target' );

done_testing();
