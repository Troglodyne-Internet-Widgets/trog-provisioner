#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-fail2ban.t - the jails that recipes declare, and the one
file that fail2ban makes of them

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();
use Provisioner::Recipe();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);
my %G = (
    domain      => 'jail.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'admin',
);

sub recipe {
    my ($name) = @_;
    return Provisioner::Cookbook->load( $name, distro => 'ubuntu' )->new(%PROV);
}

subtest 'a recipe that declares jails depends on fail2ban for them' => sub {
    my %req = Provisioner::Recipe::required_recipes( recipe('nginx'), %G );
    ok( $req{fail2ban}, 'nginx requires fail2ban' ) or return;
    is_deeply(
        { $req{fail2ban}->() },
        { jails => { 'nginx-http-auth' => { backend => 'auto' }, 'nginx-botsearch' => { backend => 'auto' } } },
        'and hands it the jails that fail2ban ships for nginx, reading its log file'
    );

    my %mail = Provisioner::Recipe::required_recipes( recipe('mail'), %G );
    is_deeply( [ sort keys %{ { $mail{fail2ban}->() }->{jails} } ], [qw{dovecot postfix}], 'mail hands it postfix and dovecot' );

    my %ntp = Provisioner::Recipe::required_recipes( recipe('ntp'), %G );
    ok( !$ntp{fail2ban}, 'and a recipe with no jails does not require it' );
};

subtest 'the jail of tpsgi is its own, and named for the domain' => sub {
    my %jails = recipe('tpsgi')->jails(%G);
    my $jail  = $jails{'tpsgi-jail.test.test'};
    ok( $jail, 'named for the domain, so that two domains on one guest do not collide' ) or return;
    is( $jail->{filter},  '',                                          'with no filter file to look for' );
    is( $jail->{logpath}, '/opt/domains/jail.test.test/log/tpsgi.log', 'reading the log of the domain' );
    is( $jail->{backend}, 'auto',                                      'as a file, not the journal' );
    like( $jail->{failregex},   qr/<HOST>/,               'with a failregex that names the host' );
    like( $jail->{failregex},   qr/Failed[ ]login/,       'of a failed login' );
    like( $jail->{failregex},   qr/TOTP[ ]auth[ ]failed/, 'and of a failed TOTP code' );
    like( $jail->{datepattern}, qr/\A%%Y/,                'and a datepattern with its percent signs doubled for fail2ban' );
};

subtest 'each recipe that takes a login from the public declares a jail for it' => sub {
    my %want = (
        roundcube => { 'roundcube-auth' => 'systemd[journalflags=1]' },
        gogs      => { 'gogs-login'     => 'auto' },
        grafana   => { 'grafana-login'  => 'auto' },
        matrix    => { 'matrix-login'   => 'auto' },
        garage    => { 'garage-auth'    => 'systemd' },
        openvpn   => { 'openvpn-tls'    => 'auto' },
        deluged   => {},
    );
    for my $name ( sort keys %want ) {
        my %jails = recipe($name)->jails(%G);
        is_deeply( { map { $_ => $jails{$_}{backend} } keys %jails }, $want{$name}, "$name: its jails, and the backend each reads" );
    }

    my %garage = recipe('garage')->jails( %G, api_port => 4900 );
    is( $garage{'garage-auth'}{port}, '4900,3903', 'garage bans on the ports it is configured with' );
    my %vpn = recipe('openvpn')->jails( %G, port => 11194, proto => 'tcp' );
    is_deeply( [ @{ $vpn{'openvpn-tls'} }{qw{port protocol}} ], [ 11194, 'tcp' ], 'and openvpn on its port and protocol' );
};

# Lines that each service wrote on a guest, as fail2ban hands them to a
# failregex: with the timestamp that the datepattern found cut out of a file.
# A journal entry keeps its text whole.
my @LINES = (
    [ tpsgi => 'tpsgi-jail.test.test', 1, '192.0.2.104',    q{ [INFO]: RequestId INIT From ::ffff:192.0.2.104 |nobody| Failed login for user someadmin} ],
    [ tpsgi => 'tpsgi-jail.test.test', 0, undef,            q{[Worker 1957831] {Request 3c8d2e5b-83ed-48e9-a3e9-539fd77d9294} [someadmin]  : 0.0.0.0 Opening Log /home/someadmin/Code/tPSGI/log/tpsgi.log at debug level} ],
    [ gogs  => 'gogs-login',           1, '192.168.122.57', q{192.168.122.57 - - [] "POST /user/login HTTP/1.1" 200 7562 "-" "curl/8.5.0"} ],
    [ gogs  => 'gogs-login',           0, undef,            q{192.168.122.57 - - [] "GET /user/login HTTP/1.1" 200 7451 "-" "curl/8.5.0"} ],
    [
        grafana => 'grafana-login', 1, '192.168.122.57',
        q{logger=context userId=0 orgId=0 uname= t= level=info msg="Request Completed" method=POST path=/login status=401 remote_addr=192.168.122.57 time_ms=25 duration=25.531434ms size=94 referer= handler=/login status_source=server errorReason=Unauthorized errorMessageID=password-auth.failed error="failed to authenticate identity: [password-auth.invalid] invalid password"}
    ],
    [ matrix  => 'matrix-login', 1, '192.168.122.50',  q{ - synapse.access.http.8008 - 643 - INFO - POST-3 - 192.168.122.50 - 8008 - {None} Processed request: 0.003sec/0.001sec ru=(0.001sec, 0.000sec) db=(0.000sec/0.000sec/1) 64B 403 "POST /_matrix/client/v3/login HTTP/1.1" "curl/8.5.0" [0 dbevts]} ],
    [ matrix  => 'matrix-login', 1, '192.168.122.50',  q{ - synapse.access.http.8008 - 643 - INFO - POST-6 - 192.168.122.50 - 8008 - {None} Processed request: 0.501sec/0.001sec ru=(0.000sec, 0.000sec) db=(0.000sec/0.000sec/0) 80B 429 "POST /_matrix/client/v3/login HTTP/1.1" "curl/8.5.0" [0 dbevts]} ],
    [ matrix  => 'matrix-login', 0, undef,             q{ - synapse.access.http.8008 - 643 - INFO - GET-0 - 127.0.0.1 - 8008 - {None} Processed request: 0.002sec/0.000sec ru=(0.001sec, 0.000sec) db=(0.000sec/0.000sec/0) 1482B 200 "GET /_matrix/client/versions HTTP/1.1" "curl/8.5.0" [0 dbevts]} ],
    [ garage  => 'garage-auth',  1, '192.168.122.57',  q{2026-09-19T16:19:53.523536Z  INFO garage_api_common::generic_server: error 403 Forbidden, Forbidden: No such key: GKbogus0000000000000000000 in response to 192.168.122.57:53962 (key GKbogus0000000000000000000) GET /} ],
    [ garage  => 'garage-auth',  1, '192.168.122.57',  q{2026-09-19T16:19:53.546327Z  INFO garage_api_common::generic_server: error 403 Forbidden, Forbidden: Invalid bearer token in response to 192.168.122.57:58782 GET /v2/GetClusterStatus} ],
    [ openvpn => 'openvpn-tls',  1, '192.168.122.186', q{TLS Error: cannot locate HMAC in incoming packet from [AF_INET]192.168.122.186:51342} ],
    [ openvpn => 'openvpn-tls',  1, '192.168.122.50',  q{TLS Error: incoming packet authentication failed from [AF_INET]192.168.122.50:36431} ],
    [ openvpn => 'openvpn-tls',  0, undef,             q{Authenticate/Decrypt packet error: packet HMAC authentication failed} ],
);

subtest 'each failregex matches the line its service writes for a failed login, and no other' => sub {
    for my $case (@LINES) {
        my ( $name, $jail, $fails, $host, $line ) = @$case;
        my %jails = recipe($name)->jails(%G);
        my $re    = $jails{$jail}{failregex} =~ s/<HOST>/(?:::ffff:)?(?<host>[0-9a-f.:]+)/r;
        my $got   = $line                    =~ qr/(?^:$re)/;
        my $seen  = $+{host};
        if ($fails) {
            ok( $got, "$jail: matches $line" ) or next;
            is( $seen, $host, "$jail: and bans $host" );
        }
        else {
            ok( !$got, "$jail: passes over $line" );
        }
    }
};

subtest 'the jails of every recipe on the guest reach fail2ban' => sub {
    my %domain_conf = ( nginx => {}, tpsgi => { routers => ['app.psgi'] } );
    Provisioner::Cookbook->resolve_dependencies(
        modules       => [qw{nginx tpsgi}],
        domain_conf   => \%domain_conf,
        global_config => {%G},
        distro        => 'ubuntu',
        provisioner   => \%PROV,
        domain        => $G{domain},
    );
    is_deeply( [ sort keys %{ $domain_conf{fail2ban}{jails} // {} } ], [qw{nginx-botsearch nginx-http-auth tpsgi-jail.test.test}], 'merged into one set' );
};

subtest 'one file, with a section for each jail' => sub {
    my %jails = ( recipe('tpsgi')->jails(%G), postfix => {} );
    my $file  = recipe('fail2ban')->render_file( 'files/fail2ban.jail.tt', %G, jails => \%jails );

    like( $file, qr/^\[postfix\]\nenabled[ ]=[ ]true\n\n/m,                'a shipped jail is only its name, enabled' );
    like( $file, qr/^\[tpsgi-jail[.]test[.]test\]\nenabled[ ]=[ ]true\n/m, 'a jail of our own is enabled too' );
    like( $file, qr/^filter[ ]=[ ]$/m,                                     'with an empty filter' );
    like( $file, qr/^failregex[ ]=[ ].*From[ ]<HOST>[ ]/m,                 'and its failregex as written, not HTML-escaped' );
    unlike( $file, qr/&lt;/, 'nothing in it is escaped' );
};

subtest 'a jail that is not a section of an INI file is refused' => sub {
    like( exception { recipe('fail2ban')->render_file( 'files/fail2ban.jail.tt', %G, jails => { 'no]good' => {} } ) },               qr{/jails:[ ]Properties[ ]not[ ]allowed}, 'a bracket in the name' );
    like( exception { recipe('fail2ban')->render_file( 'files/fail2ban.jail.tt', %G, jails => { ok        => { nested => {} } } ) }, qr{/jails/ok/nested:},                    'or an option that is not a string' );
};

done_testing();
