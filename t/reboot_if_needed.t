#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/reboot_if_needed.t - scripts/reboot_if_needed: reboot when asked, and never while a build or the operator holds it

=cut

use Test::More;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use IPC::Run3();

use FindBin;

my $script = "$FindBin::Bin/../scripts/reboot_if_needed";

# Nothing here reboots anything.  The script calls reboot by name, so this one
# stands in for it, first on the PATH, and writes down that it was called.
my $dir      = tempdir( CLEANUP => 1 );
my $rebooted = "$dir/rebooted";
make_path("$dir/bin");
open( my $fh, '>', "$dir/bin/reboot" ) or die "$dir/bin/reboot: $!";
print {$fh} "#!/bin/sh\ntouch '$rebooted'\n";
close $fh or die "$dir/bin/reboot: $!";
chmod 0755, "$dir/bin/reboot";

my $required = "$dir/reboot-required";
my $holds    = "$dir/no-reboot";
my $switch   = "$dir/noautorestart";

# Whether one run of the script rebooted, from a clean start each time.
sub reboots {
    my (@args) = @_;
    unlink $rebooted;

    local $ENV{PATH}            = "$dir/bin:$ENV{PATH}";
    local $ENV{REBOOT_REQUIRED} = $required;
    local $ENV{NO_REBOOT_DIR}   = $holds;
    IPC::Run3::run3( [ 'bash', $script, @args ], \undef, \my $out, \my $err );
    die "reboot_if_needed exited $?: $out$err" if $?;

    return -e $rebooted ? 1 : 0;
}

sub touch {
    my ($file) = @_;
    open( my $t, '>', $file ) or die "$file: $!";
    close $t                  or die "$file: $!";
    return;
}

subtest 'nothing asked for a reboot' => sub {
    unlink $required;
    is( reboots(),        0, 'no reboot without reboot-required' );
    is( reboots($switch), 0, 'nor with a switch that is not there' );
};

touch($required);

subtest 'an update asked for a reboot' => sub {
    is( reboots(),        1, 'with no switch, it reboots' );
    is( reboots($switch), 1, 'with a switch that is not there, it reboots' );

    touch($switch);
    is( reboots($switch), 0, 'with the switch in place, it holds' );
    unlink $switch;
};

subtest 'a build holds reboots until it ends' => sub {
    make_path($holds);
    is( reboots(), 1, 'an empty hold directory holds nothing' );

    touch("$holds/d.test");
    is( reboots(),        0, 'a build in progress holds the reboot' );
    is( reboots($switch), 0, 'whatever the switch says' );

    touch("$holds/e.test");
    unlink "$holds/d.test";
    is( reboots(), 0, 'one build ending does not release the hold of another' );

    unlink "$holds/e.test";
    is( reboots(), 1, 'and once the last build ends, it reboots' );
};

done_testing();
