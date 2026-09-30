#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/bin-help.t - every script in bin/ answers --help, and refuses an option it
does not know

=head1 DESCRIPTION

An option that a script does not know must stop it before it does anything,
because it is usually a misspelling, such as C<--dry-run> for C<--dryrun>.

Each script is loaded here as well as run, so that tests-covering chooses this
test when any of them changes.

=cut

use Test::More;
use IPC::Run3();
use File::Temp qw{tempdir};

use FindBin;
use FindBin::libs;

# If a script falls through to its job, it finds no configuration to act on.
local $ENV{TROG_PROVISIONER_CONFIG} = tempdir( CLEANUP => 1 );

my @scripts = sort glob "$FindBin::Bin/../bin/*";
ok( scalar @scripts, 'there are scripts to ask' );

my sub run (@cmd) {
    my $said = q{};
    IPC::Run3::run3( [ $^X, @cmd ], \undef, \$said, \$said );
    return ( $said, $? );
}

foreach my $script (@scripts) {
    my ($name) = $script =~ m{([^/]+)\z};

    subtest $name => sub {
        require_ok($script);

        my ( $out, $rc ) = run( $script, '--help' );
        is( $rc, 0, '--help exits 0' ) or diag $out;
        like( $out, qr/\S/, 'and prints the documentation' );
        unlike( $out, qr/Unknown[ ]option/, 'which it knows as an option' );

        ( $out, $rc ) = run( $script, '--no-such-option' );
        is( $rc >> 8, 2, 'an option it does not know exits 2' ) or diag $out;
        like( $out, qr/Unknown[ ]option:[ ]no-such-option/, 'naming the option' );
        like( $out, qr/Usage:/,                             'with the usage' );
    };
}

done_testing;
