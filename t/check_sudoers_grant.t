#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/check_sudoers_grant.t - scripts/check_sudoers_grant: a sudoers file passes
only when sudo reads exactly the commands asked for

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempdir};
use File::Slurper::Temp();
use File::Which();
use Capture::Tiny qw{capture_stderr};

use FindBin;

my $script = "$FindBin::Bin/../scripts/check_sudoers_grant";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

plan skip_all => 'no cvtsudoers here, and the check is what cvtsudoers reads' unless File::Which::which('cvtsudoers');

my $dir = tempdir( CLEANUP => 1 );
my $n   = 0;

# A sudoers file of @lines, and a file of the commands in @asked.  Returns the
# exit of main and what it printed.
sub check {
    my ( $lines, $asked ) = @_;
    $n++;
    File::Slurper::Temp::write_text( "$dir/sudoers$n",  join( q{}, map { "$_\n" } @$lines ) );
    File::Slurper::Temp::write_text( "$dir/commands$n", join( q{}, map { "$_\n" } @$asked ) );
    my $exit;
    my $said = capture_stderr { $exit = Trog::CheckSudoersGrant::main( "$dir/sudoers$n", 'svc', "$dir/commands$n" ) };
    return ( $exit, $said );
}

my @asked = ( '/usr/bin/systemctl restart ssh', '/usr/bin/id ""' );
my @grant = map { "svc ALL=(root) NOPASSWD: $_" } @asked;

my ( $exit, $said ) = check( \@grant, \@asked );
is( $exit, 0, 'a file that grants exactly the commands passes' ) or diag $said;

( $exit, $said ) = check( ['# nothing'], [] );
is( $exit, 0, 'and so does a file that grants nothing, for no commands' ) or diag $said;

my %wider = (
    'a # in an argument, which starts a comment' => [ ['svc ALL=(root) NOPASSWD: /usr/bin/ls #-l'],         ['/usr/bin/ls #-l'] ],
    'a comma, which starts a second command'     => [ ['svc ALL=(root) NOPASSWD: /usr/bin/id "", /bin/sh'], ['/usr/bin/id "", /bin/sh'] ],
    'a rule that asks for a password'            => [ ['svc ALL=(root) /usr/bin/id ""'],                    ['/usr/bin/id ""'] ],
    'a rule as another user than root'           => [ ['svc ALL=(ALL) NOPASSWD: /usr/bin/id ""'],           ['/usr/bin/id ""'] ],
    'a rule for another user'                    => [ ['other ALL=(root) NOPASSWD: /usr/bin/id ""'],        ['/usr/bin/id ""'] ],
    'a grant beside no commands'                 => [ ['svc ALL=(root) NOPASSWD: /usr/bin/id ""'],          [] ],
);
foreach my $case ( sort keys %wider ) {
    ( $exit, $said ) = check( @{ $wider{$case} } );
    is( $exit, 1, "a file with $case fails" ) or diag $said;
    like( $said, qr/sudo[ ]reads:.*asked[ ]for:/, 'and says what sudo reads, and what was asked for' );
}

( $exit, $said ) = check( \@grant, [ reverse @asked ] );
is( $exit, 1, 'the order of the commands matters, because the rules are compared one by one' );

like( exception { check( ['svc ALL=(root) NOPASSWD /usr/bin/id'], ['/usr/bin/id'] ) }, qr/cvtsudoers[ ]could[ ]not[ ]read/, 'a file that cvtsudoers cannot read dies' );
like( exception { Trog::CheckSudoersGrant::main( "$dir/sudoers1", 'svc' ) },           qr/usage/,                           'and so do missing arguments' );

had_no_warnings();
done_testing;
