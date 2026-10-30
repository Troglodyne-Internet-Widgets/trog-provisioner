#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/check_edge.t - bin/check_edge: each check of an edge guest, from the answers of the machines

=cut

use Test::More;
use Capture::Tiny    qw{capture_stdout};
use Test::MockModule qw{strict};
use Socket();

use FindBin;
use FindBin::libs;

# Never the configuration of the installation.
## no critic (CompileTime) -- setting it at compile time is the point
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns

my $script = "$FindBin::Bin/../bin/check_edge";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# A guest that answers each command by the first rule whose pattern matches
# it.  A rule gives the output and the exit status, as a shell on the far side
# would print them through as_root.  A command that no rule matches gets
# nothing, as a connection that failed does.  A Trog::Guest, so that a method
# the real one lacks fails here too.
{

    package FakeMachine;
    use parent 'Trog::Guest';
    sub new { my ( $class, %o ) = @_; return $class->SUPER::new( rules => [], asked => [], %o ) }

    sub capture_cmd {
        my ( $self, $command ) = @_;
        push @{ $self->{asked} }, $command;
        foreach my $rule ( @{ $self->{rules} } ) {
            my ( $pattern, $answer ) = @$rule;
            next unless $command =~ $pattern;
            my ( $out, $status ) = ref $answer eq 'CODE' ? $answer->($command) : @$answer;
            return defined $status ? "${out}check-edge-status=$status\n" : $out;
        }
        return;
    }
}

sub machine { my (@rules) = @_; return FakeMachine->new( host => '192.0.2.10', rules => [@rules] ) }

subtest 'as_root: the output and the exit status of a command on the far side' => sub {
    my $m = machine( [ qr/true/ => [ "said\n", 0 ] ], [ qr/false/ => [ q{}, 3 ] ] );
    is_deeply( [ Provisioner::Bin::check_edge::as_root( $m, 'true' ) ],  [ "said\n", 0 ],     'what it printed, and 0' );
    is_deeply( [ Provisioner::Bin::check_edge::as_root( $m, 'false' ) ], [ q{},      3 ],     'and a status that is not 0' );
    is_deeply( [ Provisioner::Bin::check_edge::as_root( $m, 'lost' ) ],  [ q{},      undef ], 'and no status when the command printed none' );
    like( $m->{asked}[0], qr/\Asudo[ ]sh[ ]-c[ ]'true;/, 'as root' );

    my ($quoted) = Provisioner::Bin::check_edge::as_root( machine( [ qr/./ => sub { return ( "$_[0]\n", 0 ) } ] ), q{echo 'x'} );
    like( $quoted, qr/'echo[ ]'\\''x'\\''/, 'with a single quote in the command kept inside the quotes of sh -c' );
};

subtest 'check_tunnel: a route through a tunnel to the address of the guest in the pool, and an answer there' => sub {
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( guest_address => sub { return ( $_[0], '192.168.1.48' ) } );

    my $up = machine( [ qr/route[ ]get[ ]192[.]168[.]1[.]48\b/ => [ "192.168.1.48 dev tun-abc src 10.8.0.129\n", 0 ] ], [ qr/ping[ ].*[ ]192[.]168[.]1[.]48\b/ => [ "1 received\n", 0 ] ] );
    my $ok = Provisioner::Bin::check_edge::check_tunnel( $up, 'guest.test' );
    is( $ok->[0], 1, 'passes when both hold' ) or diag explain $up->{asked};
    like( $ok->[1], qr/at[ ]192[.]168[.]1[.]48[ ]/, 'at the address in the pool, which is where the edge proxies to' );

    my $lan = machine( [ qr/route[ ]get/ => [ "192.168.1.48 dev eth0 src 192.168.1.9\n", 0 ] ] );
    my $off = Provisioner::Bin::check_edge::check_tunnel( $lan, 'guest.test' );
    is( $off->[0], 0, 'fails on a route outside a tunnel' );
    like( $off->[2], qr/outside[ ]a[ ]tunnel/, 'and says so' );

    my $mute = machine( [ qr/route[ ]get/ => [ "192.168.1.48 dev tun-abc\n", 0 ] ], [ qr/ping/ => [ "0 received\n", 1 ] ] );
    like( Provisioner::Bin::check_edge::check_tunnel( $mute, 'guest.test' )->[2], qr/does[ ]not[ ]answer[ ]a[ ]ping/, 'and on a guest that does not answer' );

    $pool->redefine( guest_address => sub { return ( 'host.test', undef ) } );
    my $none = Provisioner::Bin::check_edge::check_tunnel( $up, 'guest.test' );
    is( $none->[0], 0, 'and when the guest has no address in the pool' );
    like( $none->[2], qr/\Ahost[.]test[ ]has[ ]no[ ]address/, 'naming the guest that runs the domain' );
};

subtest 'edge_addresses: each address of the edge in the pool, then the one this machine reaches it at' => sub {
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( holdings => sub { return $_[0] eq 'edge.test' ? { vpnclients => '10.8.0.129', guests => '192.168.1.9' } : {} } );
    is_deeply( [ Provisioner::Bin::check_edge::edge_addresses( machine(), 'edge.test' ) ],  [qw{10.8.0.129 192.168.1.9 192.0.2.10}], 'all of them' );
    is_deeply( [ Provisioner::Bin::check_edge::edge_addresses( machine(), 'cloud.test' ) ], ['192.0.2.10'],                          'and only the last when the pool has none' );
};

subtest 'check_resolvers: the edge resolves a name through its own resolvers, and each answers' => sub {
    my $answer = ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\nname.test. 300 IN A 198.51.100.9\n";
    is( Provisioner::Bin::check_edge::check_resolvers( machine( [ qr/dig[ ][+]time/ => [ $answer, 0 ] ] ), 'name.test' )->[0], 1, 'passes when the answer comes' );

    my $slow = Provisioner::Bin::check_edge::check_resolvers( machine( [ qr/dig/ => [ ";; communications error to 192.168.1.254#53: timed out\n$answer", 0 ] ] ), 'name.test' );
    is( $slow->[0], 0, 'fails when one resolver does not answer, though another one does' );
    like( $slow->[2], qr/192[.]168[.]1[.]254\#53:[ ]timed[ ]out/, 'and quotes which one' );

    my $none = Provisioner::Bin::check_edge::check_resolvers( machine( [ qr/dig/ => [ ";; communications error to 192.168.1.254#53: timed out\n;; no servers could be reached\n", 9 ] ] ), 'name.test' );
    like( $none->[2], qr/no[ ]servers[ ]could[ ]be[ ]reached/, 'and when none answers' );

    my $nx = Provisioner::Bin::check_edge::check_resolvers( machine( [ qr/dig/ => [ ";; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n", 0 ] ] ), 'name.test' );
    is( $nx->[0], 0, 'and when the name does not resolve' );
};

subtest 'check_client_address: the request in the log of the guest, from the client' => sub {
    my $token = 'check-edge-abc';
    my $line  = sub { my ($from) = @_; return machine( [ qr/journalctl/ => [ qq{$from - - [28/Oct/2026:19:00:00 +0000] "GET /$token HTTP/1.1" 404 0 "-" "check_edge"\n}, 0 ] ] ) };

    is( Provisioner::Bin::check_edge::check_client_address( $line->('203.0.113.7'), $token, '203.0.113.7', '198.51.100.9' )->[0], 1, 'passes when the guest logs the address of the client' );

    my $edge = Provisioner::Bin::check_edge::check_client_address( $line->('10.8.0.129'), $token, qw{203.0.113.7 10.8.0.129 198.51.100.9} );
    is( $edge->[0], 0, 'fails when it logs the address of the edge' );
    like( $edge->[2], qr/which[ ]is[ ]the[ ]edge/, 'and names it, when it is the tunnel of the edge and not the address this machine reaches it at' );

    like( Provisioner::Bin::check_edge::check_client_address( $line->('192.0.2.99'), $token, '203.0.113.7', '10.8.0.129' )->[2], qr/neither[ ]the[ ]edge/, 'and says when it is neither' );

    my $none = Provisioner::Bin::check_edge::check_client_address( machine( [ qr/journalctl/ => [ q{}, 1 ] ] ), $token, '203.0.113.7', '10.8.0.129' );
    like( $none->[2], qr/no[ ]request[ ]for[ ]\/\Q$token\E/, 'and when the log has no such request' );

    like( Provisioner::Bin::check_edge::check_client_address( machine(), $token, undef, '10.8.0.129' )->[2], qr/did[ ]not[ ]say/, 'and when the edge did not say where the client is' );
};

subtest 'client_address: the source of the ssh connection to the edge' => sub {
    my $edge = machine( [ qr/SSH_CONNECTION/ => sub { return "203.0.113.7 51234 198.51.100.9 22\n" } ] );
    is( Provisioner::Bin::check_edge::client_address($edge), '203.0.113.7', 'the first field' );
};

subtest 'check_ban: the ban reaches the edge, and the unban leaves it' => sub {
    no warnings 'once';
    local $Provisioner::Bin::check_edge::BAN_WAIT = 0;
    use warnings;
    my %in_set;
    my $guest = machine(
        [ qr/fail2ban-client[ ]status/        => [ "|- Number of jail: 2\n`- Jail list:\tsshd, nginx-http-auth\n", 0 ] ],
        [ qr/get[ ]sshd[ ]actions/            => [ "ufw\n",                                                        0 ] ],
        [ qr/get[ ]nginx-http-auth[ ]actions/ => [ "ufw\nnginxrelay-guest.test\n",                                 0 ] ],
        [ qr/banip[ ](\S+)/                   => sub { $in_set{ ( $_[0] =~ m/banip[ ](\S+)/ )[0] } = $_[0] !~ m/unbanip/; return ( q{}, 0 ) } ],
    );
    my $edge = machine( [ qr/ipset[ ]-quiet[ ]test/ => sub { my ($ip) = $_[0] =~ m/test[ ]\S+[ ](\S+)/; return ( q{}, $in_set{$ip} ? 0 : 1 ) } ] );

    my $result = Provisioner::Bin::check_edge::check_ban( $guest, $edge, 'guest.test' );
    is( $result->[0], 1, 'passes when the address arrives in the set and leaves it' );
    like( $result->[1], qr/nginx-http-auth/, 'through the jail that bans through the edge' );
    ok( ( grep { m/unbanip/ } @{ $guest->{asked} } ), 'and it unbans what it banned' );

    my $deaf = machine( [ qr/ipset/ => [ q{}, 1 ] ] );
    my $lost = Provisioner::Bin::check_edge::check_ban( $guest, $deaf, 'guest.test' );
    like( $lost->[2], qr/did[ ]not[ ]reach/, 'fails when the ban does not reach the edge' );
    ok( ( grep { m/unbanip/ } @{ $guest->{asked} } ), 'and unbans it anyway' );

    my $stuck = machine( [ qr/ipset/ => [ q{}, 0 ] ] );
    like( Provisioner::Bin::check_edge::check_ban( $guest, $stuck, 'guest.test' )->[2], qr/unban[ ]did[ ]not/, 'and when the unban does not take it out' );

    my $alone = machine( [ qr/status/ => [ "`- Jail list:\tsshd\n", 0 ] ], [ qr/actions/ => [ "ufw\n", 0 ] ] );
    my $why   = Provisioner::Bin::check_edge::check_ban( $alone, $edge, 'guest.test' )->[2];
    cmp_ok( index( $why, 'No jail of the guest bans through the action nginxrelay-guest.test' ), '>=', 0, 'and when no jail bans through the edge' ) or diag $why;
};

subtest 'http_status: the status of the answer' => sub {
    my $ask = sub {
        my ($answer) = @_;
        socketpair( my $near, my $far, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC() ) or die "socketpair: $!";
        $_->autoflush(1) for $near, $far;
        print {$far} $answer;
        shutdown( $far, 1 );
        my $status = Provisioner::Bin::check_edge::http_status( $near, 'name.test', '/x' );
        close($near) or die "close: $!";
        my $sent = do { local $/; <$far> }
          // q{};
        return ( $status, $sent );
    };
    my ( $status, $sent ) = $ask->("HTTP/1.1 301 Moved Permanently\r\n\r\n");
    is( $status, 301, 'the code of the status line' );
    like( $sent, qr{\AGET[ ]/x[ ]HTTP/1[.]1\r\nHost:[ ]name[.]test\r\n}, 'for the path and the host it was given' );
    is( ( $ask->("SSH-2.0-OpenSSH_9.6\r\n") )[0], undef, 'and nothing for an answer that is not HTTP' );
};

subtest 'check_https and check_http: a connection and an HTTP answer' => sub {
    my $mock = Test::MockModule->new( 'Provisioner::Bin::check_edge', no_auto => 1 );
    my $ssl  = Test::MockModule->new('IO::Socket::SSL');
    my $ip   = Test::MockModule->new('IO::Socket::IP');
    $mock->redefine( http_status => sub { return 200 } );

    my %asked;
    $ssl->redefine( new => sub { my ( undef, %o ) = @_; %asked = %o; return bless {}, 'IO::Socket::SSL' } );
    my $ok = Provisioner::Bin::check_edge::check_https(qw{198.51.100.9 name.test tok});
    is( $ok->[0], 1, 'HTTPS passes with a verified connection and an answer' );
    is_deeply( [ @asked{qw{PeerHost PeerPort SSL_hostname SSL_verifycn_name}} ], [ '198.51.100.9', 443, 'name.test', 'name.test' ], 'to port 443 of the edge, with the name in SNI and in the check of the certificate' );
    is( $asked{SSL_verify_mode}, IO::Socket::SSL::SSL_VERIFY_PEER(), 'and the certificate verified' );

    $ssl->redefine( new => sub { return } );
    like( Provisioner::Bin::check_edge::check_https(qw{198.51.100.9 name.test tok})->[2], qr/No[ ]verified[ ]TLS[ ]connection/, 'and fails without one' );

    $ip->redefine( new => sub { return bless {}, 'IO::Socket::IP' } );
    is( Provisioner::Bin::check_edge::check_http(qw{198.51.100.9 name.test})->[0], 1, 'HTTP passes with an answer' );
    $mock->redefine( http_status => sub { return } );
    like( Provisioner::Bin::check_edge::check_http(qw{198.51.100.9 name.test})->[2], qr/no[ ]HTTP[ ]answer/, 'and fails without one' );
};

subtest 'main: a line for each check, and the exit status' => sub {
    my $mock = Test::MockModule->new( 'Provisioner::Bin::check_edge', no_auto => 1 );
    $mock->redefine( machine => sub { return FakeMachine->new( host => $_[0] ) } );
    my @tunnel;
    $mock->redefine( check_tunnel         => sub { @tunnel = @_; return [ 1, 'tunnel' ] } );
    $mock->redefine( edge_addresses       => sub { return '10.8.0.129' } );
    $mock->redefine( check_resolvers      => sub { return [ 1, 'resolvers' ] } );
    $mock->redefine( check_https          => sub { return [ 1, 'https' ] } );
    $mock->redefine( check_http           => sub { return [ 0, 'http', "first line\nsecond line" ] } );
    $mock->redefine( client_address       => sub { return '203.0.113.7' } );
    $mock->redefine( check_client_address => sub { return [ 1, 'client' ] } );
    $mock->redefine( check_ban            => sub { return [ 1, 'ban' ] } );

    my $status;
    my $out = capture_stdout { $status = Provisioner::Bin::check_edge::main(qw{edge.test guest.test name.test}) };
    is( $tunnel[1], 'guest.test', 'the tunnel is checked for the domain of the guest, whose address the pool has' );
    like( $out, qr/^ok[ ]1[ ]-[ ]tunnel$/m,                     'a line for each check, numbered' );
    like( $out, qr/^not[ ]ok[ ]4[ ]-[ ]http$/m,                 'a failure as not ok' );
    like( $out, qr/^\#[ ]+first[ ]line\n\#[ ]+second[ ]line$/m, 'with each line of its reason under it' );
    like( $out, qr/^1[.][.]6$/m,                                'and the count of checks at the end' );
    is( $status, 1, 'and it returns 1 when a check failed' );

    $mock->redefine( check_http => sub { return [ 1, 'http' ] } );
    capture_stdout { $status = Provisioner::Bin::check_edge::main(qw{edge.test guest.test name.test}) };
    is( $status, 0, 'and 0 when every check passed' );
};

done_testing();
