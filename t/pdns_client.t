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
use File::Temp();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/pdns_client";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# The files of the recursor, here and not in /etc/powerdns.
my $recursor = File::Temp::tempdir( CLEANUP => 1 );
{
    no warnings 'once';
    $Trog::PdnsClient::FORWARDS = "$recursor/forward-zones";
    $Trog::PdnsClient::ANCHORS  = "$recursor/recursor.lua";
}

sub lines_in {
    my ($file) = @_;
    open( my $fh, '<', $file ) or return ();
    my @lines = <$fh>;
    close $fh or die "Cannot read $file: $!\n";
    chomp @lines;
    return @lines;
}

sub write_file {
    my ( $file, @lines ) = @_;
    open( my $fh, '>', $file ) or die "Cannot write $file: $!\n";
    print {$fh} map { "$_\n" } @lines;
    close $fh or die "Cannot write $file: $!\n";
    return;
}

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

    my @steps = map { is_acl($_) ? join( q{ }, @{ $_->{command} }[ 6 .. 7 ] ) : is_api($_) ? $_->{command}[7] : join( q{ }, @{ $_->{command} } ) } @{$ran};
    is_deeply(
        \@steps,
        [ 'token remove', 'DELETE', 'POST', 'token add', 'grant add', 'rec_control reload-zones', 'rec_control reload-lua-config' ],
        'the old token and zone go first, then the zone, the token and its second grant, and the recursor reads its files again'
    );
    ok( ( grep { $_ eq "$NAME=127.0.0.1:2500" } lines_in("$recursor/forward-zones") ),        'the recursor forwards the zone here' );
    ok( ( grep { index( $_, qq{addNTA("$NAME"} ) == 0 } lines_in("$recursor/recursor.lua") ), 'with a negative trust anchor' );

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
    write_file( "$recursor/forward-zones", "$NAME=127.0.0.1:2500",          "other.test=192.0.2.9" );
    write_file( "$recursor/recursor.lua",  qq{addNTA("$NAME", "a reason")}, qq{addNTA("other.test", "forwarded")} );

    my ( $ran, $rc, $err ) = against( sub { return ( 'not there', 0 ) }, 'release', $NAME );
    is( $err,           undef, 'it succeeds where the token and the zone are gone already' );
    is( $rc,            0,     'and exits 0, where the recursor does not answer either' );
    is( scalar @{$ran}, 3,     'after it asked for both to go, and asked the recursor to read its files' );
    is_deeply( [ lines_in("$recursor/forward-zones") ], ['other.test=192.0.2.9'],                'the forward of the zone goes, and another stays' );
    is_deeply( [ lines_in("$recursor/recursor.lua") ],  [qq{addNTA("other.test", "forwarded")}], 'and so does its trust anchor' );
};

subtest 'a forward that the recursor does not take stops issue before it prints a token' => sub {
    my ( undef, undef, $err, $out ) = against(
        sub {
            my ($command) = @_;
            return ( 'no recursor', $command->[0] eq 'rec_control' ? 0 : 1 );
        },
        'issue', $NAME,
        $NS
    );
    like( $err, qr/The[ ]recursor[ ]did[ ]not[ ]reload-zones:[ ]no[ ]recursor/, 'it says what the recursor said' );
    is( $out, q{}, 'and prints no token' );
};

subtest 'forwards forwards each zone in the database, once, and asks the recursor nothing' => sub {
    write_file( "$recursor/forward-zones", "own.test=127.0.0.1:2500", 'elsewhere.test=192.0.2.9' );
    write_file( "$recursor/recursor.lua", q{addNTA("own.test", "the zone of the domain")} );

    my ( $ran, $rc, $err ) = against( sub { return ( "own.test\nClient.other.test.\nnot a name\n", 1 ) }, 'forwards' );
    is( $err, undef, 'it succeeds' );
    is( $rc,  0,     'and exits 0' );
    is_deeply( [ map { $_->{command}[0] } @{$ran} ], ['sqlite3'], 'it reads the database, and reloads nothing, because the build starts the recursor after it' );

    my @forwards = lines_in("$recursor/forward-zones");
    is_deeply( [ sort @forwards ], [ sort qw{client.other.test=127.0.0.1:2500 elsewhere.test=192.0.2.9 own.test=127.0.0.1:2500} ], 'each zone once, in the form that DNS compares, and a forward elsewhere stays' );
    my @anchors = lines_in("$recursor/recursor.lua");
    is( scalar( grep { index( $_, 'addNTA("own.test"' ) == 0 } @anchors ),          1, 'a zone with a trust anchor has one still' );
    is( scalar( grep { index( $_, 'addNTA("client.other.test"' ) == 0 } @anchors ), 1, 'and a zone without one gets one' );

    ( undef, undef, $err ) = against( sub { return ( 'no such file', 0 ) }, 'forwards' );
    like( $err, qr/Could[ ]not[ ]read[ ]the[ ]zones/, 'a database that cannot be read stops it' );
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
