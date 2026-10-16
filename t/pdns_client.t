#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

# The script is loaded when the test runs rather than when it compiles, so perl
# sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/pdns_client.t - scripts/pdns_client: what it asks of the API and of
C<pdns-acl>, in which order, and what it prints

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Capture::Tiny    qw{capture};
use Test::MockModule qw{strict};
use List::Util();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/pdns_client";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $NAME = 'web.lab.test.test';
my $NS   = 'ns.test.test';

# Runs the script with every command answered by $answer, which gets the
# command and its input.  Returns what it ran, and what main returned or died
# with, and what it printed.
sub against {
    my ( $answer, @args ) = @_;

    my @ran;
    my $mock = Test::MockModule->new( 'Trog::PdnsClient', no_auto => 1 );
    $mock->redefine( api_key => sub { return 'the-key' } );
    $mock->redefine(
        run => sub {
            my ( $command, $input ) = @_;
            push( @ran, { command => [ @{$command} ], input => $input } );
            return $answer->( $command, $input );
        }
    );

    my ( $rc, $err );
    my ($out) = capture {
        $err = exception { $rc = Trog::PdnsClient::main(@args) };
    };
    return ( \@ran, $rc, $err, $out );
}

sub is_acl { my ($run) = @_; return $run->{command}[0] eq 'runuser' }
sub is_api { my ($run) = @_; return $run->{command}[0] eq 'curl' }

subtest 'issue replaces the zone and the token, and prints the new token' => sub {
    my ( $ran, $rc, $err, $out ) = against(
        sub {
            my ($command) = @_;
            return ( ( List::Util::any { $_ eq 'add' } @{$command} ) && ( List::Util::any { $_ eq 'token' } @{$command} ) ? 'a-new-token' : q{} ), 1;
        },
        'issue',
        $NAME,
        $NS
    );

    is( $err, undef,         'it succeeds' );
    is( $rc,  0,             'and exits 0' );
    is( $out, 'a-new-token', 'and prints the token, and nothing else' );

    my @steps = map { is_acl($_) ? join( q{ }, @{ $_->{command} }[ 6 .. 7 ] ) : $_->{command}[7] } @{$ran};
    is_deeply( \@steps, [ 'token remove', 'DELETE', 'POST', 'token add', 'grant add' ], 'the old token and zone go first, then the zone, the token and its second grant' );

    my ($post) = grep { is_api($_) && $_->{command}[7] eq 'POST' } @{$ran};
    like( join( q{ }, @{ $post->{command} } ), qr{"name":[ ]"\Q$NAME\E[.]".*"nameservers":[ ]\["\Q$NS\E[.]"\]}, 'the zone is the name, with the nameserver it was given' );
    is( $post->{input}, "X-API-Key: the-key\n", 'and the key goes to curl on its standard input' );
    unlike( join( q{ }, map { @{ $_->{command} } } @{$ran} ), qr/the-key/, 'and on no command line' );

    my ($grant) = grep { is_acl($_) && $_->{command}[6] eq 'grant' } @{$ran};
    like( join( q{ }, @{ $grant->{command} } ), qr{--name[ ][*][.]\Q$NAME\E[.][ ]--write}, 'the second grant writes the names below it' );
};

subtest 'a step that fails stops it before it prints a token' => sub {
    my ( $ran, undef, $err, $out ) = against(
        sub {
            my ($command) = @_;
            my $post = $command->[0] eq 'curl' && List::Util::any { $_ eq 'POST' } @{$command};
            return ( 'refused', $post ? 0 : 1 );
        },
        'issue', $NAME,
        $NS
    );

    like( $err, qr/Could[ ]not[ ]make[ ]the[ ]zone[ ]\Q$NAME\E:[ ]refused/, 'a zone that PowerDNS refused is named, with what it said' );
    is( $out, q{}, 'and nothing is printed, which bin/provision reads as no token' );
    ok( !( List::Util::any { is_acl($_) && $_->{command}[7] eq 'add' } @{$ran} ), 'and no token is made for a zone that is not there' );
};

subtest 'release deletes both, and minds neither being gone' => sub {
    my ( $ran, $rc, $err ) = against( sub { return ( 'not there', 0 ) }, 'release', $NAME );
    is( $err,           undef, 'it succeeds where the token and the zone are gone already' );
    is( $rc,            0,     'and exits 0' );
    is( scalar @{$ran}, 2,     'after it asked for both to go' );
};

subtest 'run keeps what a command says to itself' => sub {

    # bin/provision reads the output of the script over ssh on a pty, which
    # joins standard error to it, and takes the whole of it as the token.
    my ( $output, $ok, $stdout, $stderr );
    ( $stdout, $stderr ) = capture { ( $output, $ok ) = Trog::PdnsClient::run( [ 'sh', '-c', 'cat; echo said; echo complained >&2' ], "given\n" ) };
    ok( $ok, 'a command that worked succeeded' );
    is( $output,           "given\nsaid\ncomplained\n", 'its output holds its input, what it said, and what it complained of' );
    is( $stdout . $stderr, q{},                         'and none of that reaches the output of the script' );

    ( undef, $ok ) = Trog::PdnsClient::run( [ 'sh', '-c', 'exit 3' ] );
    ok( !$ok, 'and a command that failed did not succeed' );
};

subtest 'it takes nothing but names of the DNS' => sub {
    like( ( against( sub { return ( q{}, 1 ) }, 'issue', 'web;reboot', $NS ) )[2], qr/usage/, 'a name that is not one is refused' );
    like( ( against( sub { return ( q{}, 1 ) }, 'issue',  $NAME ) )[2], qr/usage/, 'and issue needs the nameserver' );
    like( ( against( sub { return ( q{}, 1 ) }, 'remove', $NAME ) )[2], qr/usage/, 'and there is no other command' );
};

done_testing();
