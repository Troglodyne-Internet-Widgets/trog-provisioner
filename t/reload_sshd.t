#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/reload_sshd.t - scripts/reload_sshd: every sshd that reads sshd_config gets
the change, the fast lane included where it runs

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();
use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/reload_sshd";

# One run, with a systemctl of our own first on the PATH that logs each command
# line, and says the fast lane runs when FAKE_FASTLANE is 0.  Returns the exit
# status and the commands.
sub reload {
    my (%env) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/systemctl", <<'SH' );
#!/bin/sh
echo "systemctl $*" >> "$FAKE_LOG"
case "$1" in
is-active) exit "${FAKE_FASTLANE:-3}" ;;
reload|try-reload-or-restart) exit "${FAKE_RELOAD:-0}" ;;
esac
SH
    chmod 0755, "$dir/systemctl";

    local %ENV = ( %ENV, PATH => "$dir:$ENV{PATH}", FAKE_LOG => "$dir/log", %env );
    my ( $out, $err );
    IPC::Run3::run3( [$script], \undef, \$out, \$err );
    my $log = -e "$dir/log" ? File::Slurper::read_text("$dir/log") : q{};
    return ( $? >> 8, [ split /\n/, $log ] );
}

subtest 'without a fast lane, ssh alone' => sub {
    my ( $rc, $ran ) = reload();
    is( $rc, 0, 'it exits 0' );
    is_deeply( $ran, [ 'systemctl try-reload-or-restart ssh', 'systemctl is-active --quiet ssh-fastlane' ], 'it reloads ssh, if it runs, and asks after the fast lane' );
};

subtest 'with one, the fast lane too, which includes the configuration of ssh' => sub {
    my ( $rc, $ran ) = reload( FAKE_FASTLANE => 0 );
    is( $rc,        0,                               'it exits 0' );
    is( $ran->[-1], 'systemctl reload ssh-fastlane', 'and reloads the fast lane after ssh' );
};

subtest 'a reload that fails is a failure' => sub {
    my ($rc) = reload( FAKE_RELOAD => 1 );
    isnt( $rc, 0, 'it exits non-zero, so the postrun task that ran it fails' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
