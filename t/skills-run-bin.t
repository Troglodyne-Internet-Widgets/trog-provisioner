#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/skills-run-bin.t - the provisioning-recipes wrappers of bin/: a tool runs only with its configuration named

=cut

use Test::More;
use File::Temp qw{tempdir};
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $scripts = "$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts";

# A run of one wrapper, as the skill runs it: what it printed, and its exit
# status.
sub run_link {
    my ( $config, $link, @args ) = @_;

    local $ENV{TROG_PROVISIONER_CONFIG} = $config;
    delete $ENV{TROG_PROVISIONER_CONFIG} unless defined $config;
    my ( $out, $err );
    IPC::Run3::run3( [ $^X, "$scripts/$link", @args ], \undef, \$out, \$err );
    return ( "$out$err", $? >> 8 );
}

subtest 'each tool refuses when no configuration is named' => sub {
    foreach my $tool (qw{new_guest new_config provision destroy add_mail_user reset_mail_password remove_mail_user}) {
        my ( $said, $rc ) = run_link( undef, $tool, '--help' );
        isnt( $rc, 0, "$tool fails" );
        like( $said, qr/TROG_PROVISIONER_CONFIG[ ]is[ ]not[ ]set/, 'and says why' );
    }
};

subtest 'and runs the tool of bin/ by the same name when one is' => sub {
    my $config = tempdir( CLEANUP => 1 );
    foreach my $tool (qw{new_guest new_config provision destroy add_mail_user reset_mail_password remove_mail_user}) {
        my ( $said, $rc ) = run_link( $config, $tool, '--help' );
        is( $rc, 0, "$tool --help exits 0" ) or diag $said;
        like( $said, qr/\b\Q$tool\E\b/, 'and it is the help of that tool' );
    }
};

subtest 'or when --config names one first' => sub {
    my $config = tempdir( CLEANUP => 1 );
    foreach my $form ( [ '--config', $config ], ["--config=$config"] ) {
        my ( $said, $rc ) = run_link( undef, 'new_guest', @$form, '--help' );
        is( $rc, 0, "new_guest @$form --help exits 0, with no variable set" ) or diag $said;
        like( $said, qr/\bnew_guest\b/, 'and the tool gets the arguments after it' );
    }
    my ( $said, $rc ) = run_link( undef, 'provision', '--config' );
    isnt( $rc, 0, 'a --config with no directory fails' );
    like( $said, qr/TROG_PROVISIONER_CONFIG[ ]is[ ]not[ ]set/, 'and says why' );

    ( $said, $rc ) = run_link( undef, qw{new_guest --help --config}, tempdir( CLEANUP => 1 ) );
    isnt( $rc, 0, 'a --config after an argument of the tool is not taken, because those go to the tool unread' );
};

subtest 'run_bin under its own name runs nothing' => sub {
    my ( $said, $rc ) = run_link( tempdir( CLEANUP => 1 ), 'run_bin', '--help' );
    isnt( $rc, 0, 'it fails' );
    like( $said, qr/by[ ]the[ ]name[ ]of[ ]its[ ]link/, 'and names the links' );
};

done_testing();
