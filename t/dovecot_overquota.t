#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/dovecot_overquota.t - scripts/dovecot_overquota: the warning goes to the recipient dovecot names, as one argument

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use File::Slurper();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/dovecot_overquota";

# A dovecot-lda of our own, first on the PATH after the one the script puts
# there itself, which records the arguments it was given one to a line.
my $dir = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$dir/dovecot-lda", qq{#!/bin/sh\nprintf '%s\\n' "\$@" > "$dir/args"\ncat > "$dir/mail"\n} );
chmod( 0755, "$dir/dovecot-lda" ) or die "Cannot make the fake dovecot-lda executable: $!";

sub deliver {
    my (@args) = @_;

    unlink( "$dir/args", "$dir/mail" );
    local $ENV{PATH} = "$dir:$ENV{PATH}";
    IPC::Run3::run3( [ $script, @args ], \undef, \my $out, \my $err );
    return $? >> 8;
}

subtest 'a recipient is delivered to as one argument' => sub {
    my $to = 'bogus user@test.test';
    is( deliver($to), 0, 'it exits clean' );

    my @args = split( m/\n/, File::Slurper::read_text("$dir/args") );
    is( $args[0], '-d', 'dovecot-lda is told who to deliver to' );
    is( $args[1], $to,  'as the whole address, not split where it has a space' );
    like( File::Slurper::read_text("$dir/mail"), qr/^To:[ ]\Q$to\E$/m, 'and the mail is addressed to it' );
};

subtest 'no recipient is a failure, and nothing is delivered' => sub {
    is( deliver(), 1, 'it exits 1' );
    ok( !-e "$dir/args", 'without running dovecot-lda' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
