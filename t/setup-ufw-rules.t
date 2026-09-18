#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/setup-ufw-rules.t - scripts/setup-ufw-rules: --dry-run reaches every ufw command that changes a rule

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use File::Slurper();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/setup-ufw-rules";

# A ufw of our own, first on the PATH, which records each command line it is
# given and answers `app list` the way ufw does.
my $dir = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$dir/ufw", <<"UFW" );
#!/bin/sh
echo "\$*" >> "$dir/calls"
[ "\$*" = 'app list' ] && printf 'Available applications:\\n  OpenSSH\\n'
exit 0
UFW
chmod( 0755, "$dir/ufw" ) or die "Cannot make the fake ufw executable: $!";

sub calls {
    my (@args) = @_;

    unlink("$dir/calls");
    local $ENV{PATH} = "$dir:$ENV{PATH}";
    IPC::Run3::run3( [ $script, @args ], \undef, \my $out, \my $err );
    is( $? >> 8, 0, 'setup-ufw-rules exits clean' ) or diag $err;
    return [ grep { $_ ne 'app list' } split( m/\n/, File::Slurper::read_text("$dir/calls") ) ];
}

subtest '--dry-run' => sub {
    my $calls = calls('--dry-run');
    ok( scalar @$calls, 'ufw is asked to change something' );
    is_deeply( [ grep { !m/^--dry-run[ ]/ } @$calls ], [], 'and every one of those commands is a dry run' );
    ok( ( grep { m/^--dry-run[ ]--force[ ]delete[ ]limit[ ]in[ ]OpenSSH$/ } @$calls ), 'the limit a profile carries is not deleted' );
    ok( ( grep { m/^--dry-run[ ]allow[ ]in[ ]67:68\/udp$/ } @$calls ),                 'and DHCP is not allowed' );
};

subtest 'without --dry-run' => sub {
    my $calls = calls();
    is_deeply( [ grep { m/--dry-run/ } @$calls ], [], 'no command is a dry run' );
    ok( ( grep { $_ eq 'allow in OpenSSH' } @$calls ), 'and each profile is allowed' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
