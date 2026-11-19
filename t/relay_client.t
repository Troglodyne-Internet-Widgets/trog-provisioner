#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/relay_client.t - scripts/relay_client: what it writes for a domain on the web
relay and on the mail relay, what it refuses, and what it prints

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Capture::Tiny    qw{capture};
use Test::MockModule qw{strict};
use File::Temp();
use File::Slurper();
use File::Slurper::Temp();
use MIME::Base64();
use POSIX();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/relay_client";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my $DOMAIN = 'web.test.test';
my @NAMES  = qw{public.web.test.test www.customer.test};

# Where the guest of $DOMAIN takes IMAP, submission and POP3 over TLS.
my $ADDRESS = '192.0.2.10';

sub client_ports {
    my (@names) = @_;
    return map { ( '--port', "$_:" . join( q{,}, @names ) ) } qw{993=10993 465=10465 995=10995};
}
my @PORTS = client_ports( $DOMAIN, "mail.$DOMAIN" );

# Every command answered: ssh-keygen makes a key where it is told to, doveadm
# hashes what it reads, and nginx says what $nginx_ok says.  @ran holds the
# commands that ran.
my $nginx_ok;
my @ran;

# What openssl says of the certificate that cert checks: the host that it is
# for, whether it is still valid, its public key, and the public key of the
# private key beside it.
my %openssl;

# A fresh directory of registrations for $relay.
sub fresh_relay {
    my ($relay) = @_;
    no warnings 'once';
    $Trog::RelayClient::RELAYS{$relay}{dir} = File::Temp::tempdir( CLEANUP => 1 );
    $Trog::RelayClient::KEY_GROUP           = getgrgid( POSIX::getegid() );
    $Trog::RelayClient::DOVECOT_GROUP       = getgrgid( POSIX::getegid() );
    @ran                                    = ();
    $nginx_ok                               = 1;
    %openssl                                = ( host => 'media.web.test.test', valid => 1, pubkey => "PUBLIC\n", pkey => "PUBLIC\n" );
    return $Trog::RelayClient::RELAYS{$relay}{dir};
}

my $files  = Test::MockModule->new( 'Trog::RelayFiles',  no_auto => 1 );
my $client = Test::MockModule->new( 'Trog::RelayClient', no_auto => 1 );
$files->redefine(
    run => sub {
        my (@command) = @_;
        my $opts = ref $command[0] eq 'HASH' ? shift @command : {};
        push( @ran, "@command" );

        if ( $command[0] eq 'openssl' ) {
            my %flag = map { $_ => 1 } @command;
            return ( "Hostname $command[-1] " . ( $command[-1] eq $openssl{host} ? 'does match' : 'does NOT match' ) . " certificate\n", 1 )               if $flag{'-checkhost'};
            return ( q{},                                                                                                                $openssl{valid} ) if $flag{'-checkend'};
            return ( $openssl{pubkey},                                                                                                   1 )               if $flag{'-pubkey'};
            return ( $openssl{pkey},                                                                                                     1 )               if $command[1] eq 'pkey';
        }

        # doveadm hashes what it reads, twice over, on its standard input.
        if ( "@command" eq 'setsid --wait doveadm pw -s ARGON2ID' ) {
            my ( $first, $second ) = split m/\n/, $opts->{input} // q{};
            return ( "{ARGON2ID}hash-of-$first\n", $first eq $second ? 1 : 0 );
        }

        if ( $command[0] eq 'ssh-keygen' ) {
            my ($file) = map { $command[ $_ + 1 ] } grep { $command[$_] eq '-f' } 0 .. $#command;
            File::Slurper::Temp::write_text( $file,       "PRIVATE KEY\n" );
            File::Slurper::Temp::write_text( "$file.pub", "ssh-ed25519 AAAAbogus bans of $DOMAIN\n" );
            return ( q{}, 1 );
        }
        return ( 'nginx said no', $nginx_ok ) if $command[0] eq 'nginx';
        return ( q{},             1 );
    }
);

# What relay_client printed for @args, what it said on standard error or died
# with, and its exit status, which is undef when it died.
sub client {
    my (@args) = @_;
    my $died;
    my ( $out, $err, $rc ) = capture {
        my $status = eval { Trog::RelayClient::main(@args) };
        $died = $@;
        $status;
    };
    return ( $out, $err . $died, $rc );
}

sub register {
    my (@args) = @_;
    return client( 'nginx', 'register', @args );
}

subtest 'main: a relay that is neither, or no command, is refused' => sub {
    fresh_relay('nginx');
    like( exception { Trog::RelayClient::main( 'web', 'release', $DOMAIN ) },                                       qr/\Ausage:/, 'a relay that is not nginx or mail' );
    like( exception { Trog::RelayClient::main('nginx') },                                                           qr/\Ausage:/, 'a relay and no command' );
    like( exception { Trog::RelayClient::main( 'mail', 'cert', $DOMAIN ) },                                         qr/\Ausage:/, 'a command of the web relay on the mail relay' );
    like( exception { Trog::RelayClient::main( 'nginx', 'register-clients', $DOMAIN, $ADDRESS, $DOMAIN, @PORTS ) }, qr/\Ausage:/, 'and one of the mail relay on the web relay' );
    is_deeply( \@ran, [], 'and none of them ran anything' );
};

subtest 'nginx register: a domain registers each name, for TLS and for plain HTTP, and gets a key' => sub {
    my $relay = fresh_relay('nginx');
    my ( $out, $err, $rc ) = register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );

    is( $rc,                                                 0,                                                                             'it exits 0' ) or diag $err;
    is( File::Slurper::read_text("$relay/$DOMAIN.tls.map"),  "public.web.test.test 192.0.2.10:8443;\nwww.customer.test 192.0.2.10:8443;\n", 'each name goes to the TLS port of the guest by its SNI name' );
    is( File::Slurper::read_text("$relay/$DOMAIN.http.map"), "public.web.test.test 192.0.2.10:8080;\nwww.customer.test 192.0.2.10:8080;\n", 'and to its HTTP port by its Host header' );
    is( MIME::Base64::decode_base64($out),                   "PRIVATE KEY\n",                                                               'it prints the private half of the key, in base64' );
    unlike( $out, qr/\n/, 'on one line, which is what bin/provision takes from it' );
    my $authorized = File::Slurper::read_text("$relay/authorized_keys.root");
    my $command    = qr/command="\S+\/relay_ban[ ]nginxrelay-bans[ ]\Q$DOMAIN\E"/;
    my $options    = qr/restrict,from="192[.]0[.]2[.]10",$command/;
    like( $authorized, qr/\A$options[ ]ssh-ed25519[ ]AAAAbogus[ ]/, 'and authorizes the public half for root, to run relay_ban for the domain from the address of its guest' );
    is_deeply( [ grep { m/\A(?:nginx|systemctl)/ } @ran ], [ 'nginx -t', 'systemctl reload nginx' ], 'after nginx accepts the files, it reloads nginx' );

    register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 www.customer.test} );
    is( File::Slurper::read_text("$relay/$DOMAIN.tls.map"), "www.customer.test 192.0.2.10:8443;\n", 'a second registration replaces the first' );
};

subtest 'nginx register: a domain registers ports of its own, for the names that list them alone' => sub {
    my $relay = fresh_relay('nginx');
    my ( $out, $err, $rc ) = register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES, '--port', '8448=8449:public.web.test.test' );
    is( $rc,                                                      0,                                         'it exits 0' ) or diag $err;
    is( File::Slurper::read_text("$relay/$DOMAIN.port-8448.map"), "public.web.test.test 192.0.2.10:8449;\n", 'the name goes to the port of the guest on the address of its TLS, and the name that did not list the port does not' );

    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES, qw{--port 8448=8449:public.web.test.test --port 8448=9449:www.customer.test} );
    is( File::Slurper::read_text("$relay/$DOMAIN.port-8448.map"), "public.web.test.test 192.0.2.10:8449;\nwww.customer.test 192.0.2.10:9449;\n", 'two names can take one port to two ports of the guest' );

    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES, '--port', '8448=8449:public.web.test.test,www.customer.test' );
    is( File::Slurper::read_text("$relay/$DOMAIN.port-8448.map"), "public.web.test.test 192.0.2.10:8449;\nwww.customer.test 192.0.2.10:8449;\n", 'or list both names after one port' );
    my $server = File::Slurper::read_text("$relay/ports/8448.conf");
    like( $server, qr/^\s*listen[ ]8448;$/m,                         'nginx listens on the port' );
    like( $server, qr/include[ ]\Q$relay\E\/[*][.]port-8448[.]map;/, 'for the names in the maps of that port' );
    like( $server, qr/^\s*proxy_protocol[ ]on;$/m,                   'with the PROXY protocol' );
    ok( ( grep { $_ eq '/etc/ufw/after.init.d/nginxrelay-bans ports' } @ran ), 'and the firewall opens it' );

    register(qw{other.test.test 192.0.2.11:8443 192.0.2.11:8080 other.test.test});
    ok( !-e "$relay/other.test.test.port-8448.map", 'a domain that registers no port gets no route on it' );

    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );
    ok( !-e "$relay/$DOMAIN.port-8448.map", 'a registration without the port takes it away' );
    ok( !-e "$relay/ports/8448.conf",       'and nginx stops listening there, because no domain has it' );

    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES, '--port', '8448=8449:public.web.test.test' );
    $nginx_ok = 0;
    ( $out, $err ) = register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES, '--port', '9448=9449:public.web.test.test' );
    like( $err, qr/nginx[ ]said[ ]no/, 'a port that nginx refuses is an error' );
    ok( -e "$relay/ports/8448.conf" && -e "$relay/$DOMAIN.port-8448.map", 'and the domain keeps the port it had' );
    ok( !-e "$relay/ports/9448.conf",                                     'and nginx does not listen on the new one' );

    $nginx_ok = 1;
    client( 'nginx', 'release', $DOMAIN );
    ok( !-e "$relay/$DOMAIN.port-8448.map" && !-e "$relay/ports/8448.conf", 'a release takes the port away' );
};

subtest 'nginx register: root takes only a key that is restricted' => sub {
    my $relay = fresh_relay('nginx');
    File::Slurper::Temp::write_text( "$relay/old.test.test.ban.pub", "ssh-ed25519 AAAAbare bans of old.test.test\n" );

    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );
    my @lines = split m/\n/, File::Slurper::read_text("$relay/authorized_keys.root");
    is( scalar @lines, 1, 'a bare public key in nginxrelay.d is not authorized, because it would log in as root with no restriction' );
    like( $lines[0], qr/\Q$DOMAIN\E/, 'and the restricted key of the domain is' );
};

subtest 'nginx register: a name that another domain registered is refused' => sub {
    my $relay = fresh_relay('nginx');
    File::Slurper::Temp::write_text( "$relay/other.test.test.tls.map", "www.customer.test 192.0.2.11:8443;\n" );

    my ( $out, $err ) = register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );
    my $holds = qr/www[.]customer[.]test[ ]is[ ]registered/;
    like( $err, qr/$holds[ ]to[ ]other[.]test[.]test/, 'the refusal names the domain that holds it' );
    is( $out, q{}, 'and it prints no key' );
    ok( !-e "$relay/$DOMAIN.tls.map", 'and writes nothing for the domain' );
};

subtest 'nginx register: what nginx refuses is taken back' => sub {
    my $relay = fresh_relay('nginx');
    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );
    my $before = File::Slurper::read_text("$relay/$DOMAIN.tls.map");

    $nginx_ok = 0;
    my ( $out, $err ) = register( $DOMAIN, '192.0.2.12:8443', '192.0.2.12:8080', @NAMES );
    like( $err, qr/nginx[ ]said[ ]no/, 'the error has what nginx said' );
    is( $out,                                               q{},     'and it prints no key' );
    is( File::Slurper::read_text("$relay/$DOMAIN.tls.map"), $before, 'and the domain keeps what it had' );

    register(qw{new.test.test 192.0.2.13:8443 192.0.2.13:8080 new.test.test});
    ok( !-e "$relay/new.test.test.tls.map", 'and a domain that had nothing keeps nothing' );
};

subtest 'nginx release: a domain releases everything that it registered' => sub {
    my $relay = fresh_relay('nginx');
    register( $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES );

    $client->redefine( reload => sub { die "$_[0] is not up\n" } );
    my ( undef, $err, $rc ) = client( 'nginx', 'release', $DOMAIN );
    $client->unmock('reload');

    is( $rc, 0, 'it exits 0' );
    is_deeply( [ glob("$relay/$DOMAIN.*") ], [], 'and the maps and the key of the domain are gone' );
    is( File::Slurper::read_text("$relay/authorized_keys.root"), q{}, 'and root no longer takes the key' );
    like( $err, qr/nginx[ ]is[ ]not[ ]up/, 'an nginx that does not reload is a warning, because it reads the files when it starts' );
    ok( ( grep { $_ eq '/etc/ufw/after.init.d/nginxrelay-bans ports' } @ran ), 'and the firewall still takes the ports' );

    ( undef, undef, $rc ) = client( 'nginx', 'release', $DOMAIN );
    is( $rc, 0, 'a domain that registered nothing releases nothing, and that is no error' );
};

subtest 'nginx register: it refuses what it cannot put in a file of nginx' => sub {
    fresh_relay('nginx');
    my %bad = (
        'an upstream with no port'   => [ $DOMAIN,                                      '192.0.2.10', '192.0.2.10:8080', @NAMES ],
        'an upstream that is a name' => [ $DOMAIN,                                      'web:8443',   '192.0.2.10:8080', @NAMES ],
        'no name'                    => [ $DOMAIN,                                      qw{192.0.2.10:8443 192.0.2.10:8080} ],
        'a name with a semicolon'    => [ $DOMAIN,                                      qw{192.0.2.10:8443 192.0.2.10:8080 a.test;b} ],
        'a domain in upper case'     => [ qw{WEB.test 192.0.2.10:8443 192.0.2.10:8080}, @NAMES ],
    );
    foreach my $case ( sort keys %bad ) {
        like( exception { Trog::RelayClient::main( 'nginx', 'register', @{ $bad{$case} } ) }, qr/\Ausage:/, $case );
    }
    like( exception { Trog::RelayClient::main( 'nginx', 'release', $DOMAIN, 'extra' ) }, qr/\Ausage:/, 'a release with more than the domain' );
    my %bad_port = (
        'a port below 1024, which nginx serves itself' => '443=8443:public.web.test.test',
        'a port above 65535'                           => '70000=8449:public.web.test.test',
        'a port with no port of the guest'             => '8448:public.web.test.test',
        'a port with no names'                         => '8448=8449',
        'a port with a colon too many'                 => '8448=8449:public.web.test.test:x',
    );
    my $form = 'PORT=GUEST_PORT:NAME,..., with PORT from 1024';
    foreach my $case ( sort keys %bad_port ) {
        like( exception { Trog::RelayClient::main( 'nginx', 'register', $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', @NAMES, '--port', $bad_port{$case} ) }, qr/\Q$form\E/, $case );
    }
    my $unlisted = 'which is not among the NAMEs';
    my %bad_name = (
        'a name that the command does not pass through' => [ qw{--media media.web.test.test --port 8448=8449:media.web.test.test}, qr/'media[.]web[.]test[.]test',[ ]\Q$unlisted\E/ ],
        'an empty name'                                 => [ @NAMES, '--port', '8448=8449:public.web.test.test,', qr/names[ ]'',[ ]\Q$unlisted\E/ ],
        'a name twice on one port'                      => [ @NAMES, qw{--port 8448=8449:public.web.test.test --port 8448=9449:public.web.test.test}, qr/on[ ]8448[ ]twice/ ],
    );
    foreach my $case ( sort keys %bad_name ) {
        my @args = @{ $bad_name{$case} };
        my $said = pop @args;
        like( exception { Trog::RelayClient::main( 'nginx', 'register', $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080}, @args ) }, $said, $case );
    }
    is_deeply( \@ran, [], 'and none of them ran anything' );
};

my $MEDIA = 'media.web.test.test';
my $PEM   = "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nCHAIN\n-----END CERTIFICATE-----\n-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n";

# What cert says for $request on $pem, as client says for its arguments.
sub cert {
    my ( $request, $pem ) = @_;
    local $ENV{SSH_ORIGINAL_COMMAND} = $request;
    open( local *STDIN, '<', \$pem ) or die "Cannot read a string: $!\n";
    return client( 'nginx', 'cert', $DOMAIN );
}

subtest 'nginx register: a media name goes to the media server of the relay, which fetches it from the guest' => sub {
    my $relay = fresh_relay('nginx');
    my ( undef, $err, $rc ) = register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 public.web.test.test --media}, $MEDIA );

    is( $rc,                                                  0,                                                                                  'it exits 0' ) or diag $err;
    is( File::Slurper::read_text("$relay/$DOMAIN.tls.map"),   "public.web.test.test 192.0.2.10:8443;\n$MEDIA unix:/run/nginxrelay-media.sock;\n", 'its SNI name goes to the socket of the media server' );
    is( File::Slurper::read_text("$relay/$DOMAIN.http.map"),  "public.web.test.test 192.0.2.10:8080;\n",                                          'and it does not pass through on 80' );
    is( File::Slurper::read_text("$relay/$DOMAIN.media.map"), "$MEDIA 192.0.2.10:8080;\n",                                                        'and the media server fetches it from the HTTP port of the guest' );

    ( undef, $err, $rc ) = register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 --media}, $MEDIA );
    is( $rc, 0, 'a guest can register media names alone' ) or diag $err;

    register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 public.web.test.test} );
    ok( !-e "$relay/$DOMAIN.media.map", 'and a registration without them takes them away' );

    like( exception { Trog::RelayClient::main( 'nginx', 'register', $DOMAIN, '192.0.2.10:8443', '192.0.2.10:8080', $MEDIA, '--media', $MEDIA ) }, qr/\Q$MEDIA\E[ ]is[ ]named[ ]twice/, 'a name cannot be both' );

    File::Slurper::Temp::write_text( "$relay/other.test.test.tls.map", "$MEDIA 192.0.2.11:8443;\n" );
    ( undef, $err ) = register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 --media}, $MEDIA );
    like( $err, qr/\Q$MEDIA\E[ ]is[ ]registered[ ]to[ ]other[.]test[.]test/, 'and a media name that another domain holds is refused' );
};

subtest 'nginx media-key: the media key runs cert for its domain, from its guest alone' => sub {
    my $relay = fresh_relay('nginx');
    my ($out) = client( 'nginx', 'media-key', $DOMAIN, '192.0.2.10' );
    is( MIME::Base64::decode_base64($out), "PRIVATE KEY\n", 'it prints the private half of the key, in base64' );
    my $command = qr/command="\S+\/relay_client[ ]nginx[ ]cert[ ]\Q$DOMAIN\E"/;
    like( File::Slurper::read_text("$relay/authorized_keys.root"),                       qr/^restrict,from="192[.]0[.]2[.]10",$command[ ]/m, 'and root takes the public half for cert alone' );
    like( exception { Trog::RelayClient::main( 'nginx', 'media-key', $DOMAIN, 'web' ) }, qr/\Ausage:/,                                       'the address must be an IPv4 address' );
};

subtest 'nginx cert: a guest installs the certificate of its media name' => sub {
    my $relay = fresh_relay('nginx');
    register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 --media}, $MEDIA );
    @ran = ();

    my ( undef, $err, $rc ) = cert( "install $MEDIA", $PEM );
    is( $rc,                                                 0,                                                                                                                               'it exits 0' ) or diag $err;
    is( File::Slurper::read_text("$relay/media/$MEDIA.crt"), "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nCHAIN\n-----END CERTIFICATE-----\n", 'the certificate and its chain land under the name' );
    is( File::Slurper::read_text("$relay/media/$MEDIA.key"), "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n",                                                                 'and so does the key' );
    is( ( stat "$relay/media/$MEDIA.key" )[2] & oct 777,     oct 640,                                                                                                                         'which the group of the workers of nginx can read, and nobody else' );
    is_deeply( [ grep { m/\A(?:nginx|systemctl)/ } @ran ], [ 'nginx -t', 'systemctl reload nginx' ], 'then nginx reloads' );

    my %refused = (
        'a name that is no media name of the domain' => [ 'install public.web.test.test', $PEM,                                                             qr/no[ ]media[ ]name/ ],
        'a request that is not install'              => [ "remove $MEDIA",                $PEM,                                                             qr/\Ausage:/ ],
        'an input with no key'                       => [ "install $MEDIA",               "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n", qr/one[ ]private[ ]key/ ],
        'an input that is too long'                  => [ "install $MEDIA",               'x' x 70_000,                                                     qr/more[ ]than/ ],
    );
    foreach my $case ( sort keys %refused ) {
        my ( $request, $pem, $why ) = @{ $refused{$case} };
        ( undef, $err, $rc ) = cert( $request, $pem );
        like( $err, $why, "$case is refused" );
    }

    my %bad_cert = (
        'a certificate of another name'               => [ host  => 'other.test.test', qr/not[ ]for/ ],
        'a certificate that has expired'              => [ valid => 0,                 qr/expired/ ],
        'a key that does not go with the certificate' => [ pkey  => "OTHER\n",         qr/does[ ]not[ ]go/ ],
    );
    foreach my $case ( sort keys %bad_cert ) {
        my ( $field, $value, $why ) = @{ $bad_cert{$case} };
        my %saved = %openssl;
        $openssl{$field} = $value;
        ( undef, $err, $rc ) = cert( "install $MEDIA", $PEM =~ s/LEAF/NEW/r );
        %openssl = %saved;
        like( $err, $why, "$case is refused" );
        unlike( File::Slurper::read_text("$relay/media/$MEDIA.crt"), qr/NEW/, 'and the old certificate stays' );
    }

    $nginx_ok = 0;
    ( undef, $err ) = cert( "install $MEDIA", $PEM =~ s/LEAF/NEW/r );
    like( $err, qr/nginx[ ]said[ ]no/, 'what nginx refuses' );
    unlike( File::Slurper::read_text("$relay/media/$MEDIA.crt"), qr/NEW/, 'is taken back' );
    is( ( stat "$relay/media/$MEDIA.key" )[2] & oct 777, oct 640, 'and the key that comes back keeps its mode' );
};

subtest 'nginx release: a release takes the media names, their certificates and the media key' => sub {
    my $relay = fresh_relay('nginx');
    register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 --media}, $MEDIA );
    client( 'nginx', 'media-key', $DOMAIN, '192.0.2.10' );
    cert( "install $MEDIA", $PEM );

    my ( undef, undef, $rc ) = client( 'nginx', 'release', $DOMAIN );
    is( $rc, 0, 'it exits 0' );
    is_deeply( [ glob("$relay/$DOMAIN.*"), glob("$relay/media/*") ], [], 'and nothing of the domain is left' );
    is( File::Slurper::read_text("$relay/authorized_keys.root"), q{}, 'and root takes neither key' );
};

my $PAGE = 'web.test.test';

subtest 'nginx register: a page name goes to the page server of the relay, which fetches it from the guest' => sub {
    my $relay = fresh_relay('nginx');
    my ( undef, $err, $rc ) = register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 public.web.test.test --page}, $PAGE, '--media', $MEDIA );

    is( $rc, 0, 'it exits 0' ) or diag $err;
    is(
        File::Slurper::read_text("$relay/$DOMAIN.tls.map"),
        "public.web.test.test 192.0.2.10:8443;\n$MEDIA unix:/run/nginxrelay-media.sock;\n$PAGE unix:/run/nginxrelay-pages.sock;\n",
        'its SNI name goes to the socket of the page server'
    );
    is( File::Slurper::read_text("$relay/$DOMAIN.http.map"), "public.web.test.test 192.0.2.10:8080;\n", 'and it does not pass through on 80' );
    is( File::Slurper::read_text("$relay/$DOMAIN.page.map"), "$PAGE 192.0.2.10:8080;\n",                'and the page server fetches it from the HTTP port of the guest' );

    register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 public.web.test.test} );
    ok( !-e "$relay/$DOMAIN.page.map", 'a registration without page names takes them away' );

    like( exception { Trog::RelayClient::main( 'nginx', 'register', $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080},        $PAGE, '--page',  $PAGE ) }, qr/\Q$PAGE\E[ ]is[ ]named[ ]twice/, 'a name cannot both pass through and be a page name' );
    like( exception { Trog::RelayClient::main( 'nginx', 'register', $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 --page}, $PAGE, '--media', $PAGE ) }, qr/\Q$PAGE\E[ ]is[ ]named[ ]twice/, 'nor be a page name and a media name' );
};

subtest 'nginx cert: a guest installs the certificate of its page name, and a release takes it' => sub {
    my $relay = fresh_relay('nginx');
    register( $DOMAIN, qw{192.0.2.10:8443 192.0.2.10:8080 --page}, $PAGE );
    $openssl{host} = $PAGE;

    my ( undef, $err, $rc ) = cert( "install $PAGE", $PEM );
    is( $rc, 0, 'the key of the certificates installs it' ) or diag $err;
    ok( -e "$relay/media/$PAGE.key", 'beside the certificates of the media names' );

    client( 'nginx', 'release', $DOMAIN );
    is_deeply( [ glob("$relay/$DOMAIN.*"), glob("$relay/media/*") ], [], 'and a release leaves nothing of the page name' );
};

subtest 'upgrade: a media key that an older build salvaged runs this client' => sub {
    my $relay = fresh_relay('nginx');
    File::Slurper::Temp::write_text( "$relay/$DOMAIN.media.pub", qq{restrict,from="192.0.2.10",command="/bogus/bin/nginxrelay_client cert $DOMAIN" ssh-ed25519 AAAAbogus media of $DOMAIN\n} );
    File::Slurper::Temp::write_text( "$relay/$DOMAIN.ban.pub",   qq{restrict,from="192.0.2.10",command="/bogus/bin/relay_ban nginxrelay-bans $DOMAIN" ssh-ed25519 AAAAbogus bans of $DOMAIN\n} );

    my ( undef, $err, $rc ) = client( 'nginx', 'upgrade' );
    is( $rc, 0, 'it exits 0' ) or diag $err;
    my $authorized = File::Slurper::read_text("$relay/authorized_keys.root");
    my $ban        = qr{/bogus/bin/relay_ban[ ]nginxrelay-bans};
    like( $authorized, qr/command="\S+\/relay_client[ ]nginx[ ]cert[ ]\Q$DOMAIN\E"/, 'root takes the media key for cert of this client' );
    like( $authorized, qr/command="$ban[ ]\Q$DOMAIN\E"/,                             'and the ban key for relay_ban, as it was' );
    unlike( $authorized, qr/nginxrelay_client/, 'and no key runs the client that is gone' );

    my $before = File::Slurper::read_text("$relay/$DOMAIN.media.pub");
    client( 'nginx', 'upgrade' );
    is( File::Slurper::read_text("$relay/$DOMAIN.media.pub"), $before, 'a second upgrade changes nothing' );
};

subtest 'the servers listen where the client sends their names' => sub {
    no warnings 'once';
    require Provisioner::Cookbook;
    my %opts = Provisioner::Cookbook->load('nginxrelay')->enrich( modules => ['nginxrelay'] );
    is( $opts{media_socket}, $Trog::RelayClient::MEDIA_SOCKET, 'the recipe has its own copy of the socket, and it names the same one' );
    is( $opts{page_socket},  $Trog::RelayClient::PAGE_SOCKET,  'and so for the socket of the page server' );
};

subtest 'mail register: a domain registers a login for the relay, and releases it' => sub {
    my $relay = fresh_relay('mail');

    my ( $out, $err, $rc ) = client( 'mail', 'register', $DOMAIN, '192.0.2.10' );
    is( $rc, 0, 'it exits 0' ) or diag $err;
    chomp( my $password = $out );
    like( $password, qr/\A[[:xdigit:]]{48}\z/, 'and prints a password on one line' );

    is( File::Slurper::read_text("$relay/mail.passwd"), "$DOMAIN:{ARGON2ID}hash-of-$password\n", 'dovecot gets a login named for the domain, with the hash that doveadm made of the password, which is not kept' );
    ok( ( grep { $_ eq 'setsid --wait doveadm pw -s ARGON2ID' } @ran ), 'doveadm reads the password on its input, away from the terminal, and not on its command line' );
    is( ( stat "$relay/mail.passwd" )[2] & oct 7777,           oct 640,                          'readable by its group, and not by everybody' );
    is( File::Slurper::read_text("$relay/mail.senders"),       "\@$DOMAIN $DOMAIN\n",            'and the login owns every sender in the domain' );
    is( File::Slurper::read_text("$relay/mail.relay_domains"), "$DOMAIN OK\n",                   'the relay takes mail for the domain from the internet' );
    is( File::Slurper::read_text("$relay/mail.transport"),     "$DOMAIN smtp:[192.0.2.10]:25\n", 'and relays it to the guest, on 25' );
    is( File::Slurper::read_text("$relay/mail.recipients"),    "\@$DOMAIN OK\n",                 'for any recipient there, which the catchall of the guest delivers' );
    is_deeply( [ grep { m/\A(?:systemctl)/ } @ran ], ['systemctl reload postfix'], 'and postfix reads the tables again' );

    client(qw{mail register other.test.test 192.0.2.11});
    my ($second) = client( 'mail', 'register', $DOMAIN, '192.0.2.12' );
    my @logins   = map { m/\A([^:]+):/ } split m/\n/, File::Slurper::read_text("$relay/mail.passwd");
    is_deeply( \@logins, [ 'other.test.test', $DOMAIN ], 'a second registration replaces the login of the domain, beside the others' );
    isnt( $second, $out, 'with a new password' );

    ( undef, undef, $rc ) = client( 'mail', 'release', $DOMAIN );
    is( $rc,                                             0,                                     'a release exits 0' );
    is( File::Slurper::read_text("$relay/mail.senders"), "\@other.test.test other.test.test\n", 'and takes away the login of the domain only' );
    unlike( File::Slurper::read_text("$relay/mail.passwd"), qr/\Q$DOMAIN\E/, 'and its hash' );
    is( File::Slurper::read_text("$relay/mail.transport"), "other.test.test smtp:[192.0.2.11]:25\n", 'and its route in, leaving the others' );
};

subtest 'mail register-clients: a domain registers the names of its mail clients, and gets a key for its bans' => sub {
    my $dir   = fresh_relay('mail');
    my @names = ( $DOMAIN, "mail.$DOMAIN" );

    my ( $key, $said, $exit ) = client( 'mail', 'register-clients', $DOMAIN, $ADDRESS, @names, @PORTS );
    is( $exit,                                                 0,                                                             'it exits 0' ) or diag $said;
    is( File::Slurper::read_text("$dir/$DOMAIN.port-993.map"), "mail.$DOMAIN 192.0.2.10:10993;\n$DOMAIN 192.0.2.10:10993;\n", 'each name goes to IMAP over TLS on the guest' );
    is( File::Slurper::read_text("$dir/$DOMAIN.port-465.map"), "mail.$DOMAIN 192.0.2.10:10465;\n$DOMAIN 192.0.2.10:10465;\n", 'and to submission over TLS' );
    is( File::Slurper::read_text("$dir/$DOMAIN.port-995.map"), "mail.$DOMAIN 192.0.2.10:10995;\n$DOMAIN 192.0.2.10:10995;\n", 'and to POP3 over TLS' );
    like( File::Slurper::read_text("$dir/ports/993.conf"), qr/^\s*listen[ ]993;$/m, 'and nginx listens on each port' );
    is( MIME::Base64::decode_base64($key), "PRIVATE KEY\n", 'it prints the private half of the ban key, in base64' );
    my $ban_command = qr/command="\S+[ ]mailrelay-bans[ ]\Q$DOMAIN\E"/;
    like( File::Slurper::read_text("$dir/authorized_keys.root"), qr/\Arestrict,from="192[.]0[.]2[.]10",$ban_command/, 'which runs relay_ban for the set of this relay, from the guest alone' );
    is_deeply(
        [ grep { m{\A(?:nginx|systemctl|/etc/ufw)} } @ran ],
        [ 'nginx -t', 'systemctl reload nginx', '/etc/ufw/after.init.d/mailrelay-bans ports' ],
        'after nginx accepts the maps, it reloads nginx, and the firewall opens the ports'
    );

    my ( undef, $refused ) = client( qw{mail register-clients other.test.test 192.0.2.11}, "mail.$DOMAIN", client_ports("mail.$DOMAIN") );
    like( $refused, qr/mail[.]\Q$DOMAIN\E[ ]is[ ]registered[ ]to[ ]\Q$DOMAIN\E/, 'another domain cannot register a name that this one holds' );
    ok( !-e "$dir/other.test.test.port-993.map", 'and gets no map' );

    $nginx_ok = 0;
    my $before = File::Slurper::read_text("$dir/$DOMAIN.port-993.map");
    ( undef, $refused ) = client( 'mail', 'register-clients', $DOMAIN, $ADDRESS, 'new.test.test', client_ports('new.test.test') );
    like( $refused, qr/nginx[ ]refused[ ].*nginx[ ]said[ ]no/, 'a map that nginx refuses is an error' );
    is( File::Slurper::read_text("$dir/$DOMAIN.port-993.map"), $before, 'and the domain keeps what it had' );

    $nginx_ok = 1;
    ( undef, undef, $exit ) = client( 'mail', 'release', $DOMAIN );
    is( $exit, 0, 'a release exits 0' );
    ok( !-e "$dir/$DOMAIN.port-$_.map", "and takes away the map of $_" )                          foreach qw{993 465 995};
    ok( !-e "$dir/ports/$_.conf",       "and nginx stops listening on $_, which no domain uses" ) foreach qw{993 465 995};
    is( File::Slurper::read_text("$dir/authorized_keys.root"), q{}, 'and the ban key' );
};

subtest 'upgrade: the mail relay moves the routes that an older relay kept by service' => sub {
    my $older = fresh_relay('mail');
    File::Slurper::Temp::write_text( "$older/$DOMAIN.imaps.map",       "$DOMAIN 192.0.2.10:10993;\n" );
    File::Slurper::Temp::write_text( "$older/$DOMAIN.submissions.map", "$DOMAIN 192.0.2.10:10465;\n" );
    File::Slurper::Temp::write_text( "$older/$DOMAIN.pop3s.map",       "$DOMAIN 192.0.2.10:10995;\n" );

    my ( undef, $complaint, $upgraded ) = client( 'mail', 'upgrade' );
    is( $upgraded,                                               0,                             'it exits 0' ) or diag $complaint;
    is( File::Slurper::read_text("$older/$DOMAIN.port-993.map"), "$DOMAIN 192.0.2.10:10993;\n", 'the routes of IMAP go to the map of 993' );
    is( File::Slurper::read_text("$older/$DOMAIN.port-465.map"), "$DOMAIN 192.0.2.10:10465;\n", 'of submission to 465' );
    is( File::Slurper::read_text("$older/$DOMAIN.port-995.map"), "$DOMAIN 192.0.2.10:10995;\n", 'of POP3 to 995' );
    ok( !-e "$older/$DOMAIN.$_.map", "and the map of $_ is gone" ) foreach qw{imaps submissions pop3s};
    ok( -e "$older/ports/$_.conf",   "nginx listens on $_ again" ) foreach qw{993 465 995};
    my ( undef, $refused ) = client( qw{mail register-clients other.test.test 192.0.2.11}, $DOMAIN, client_ports($DOMAIN) );
    like( $refused, qr/is[ ]registered[ ]to[ ]\Q$DOMAIN\E/, 'and the names stay taken' );

    ( undef, $complaint, $upgraded ) = client( 'mail', 'upgrade' );
    is( $upgraded,                                               0,                             'a second upgrade changes nothing' ) or diag $complaint;
    is( File::Slurper::read_text("$older/$DOMAIN.port-993.map"), "$DOMAIN 192.0.2.10:10993;\n", 'and keeps the routes' );
};

subtest 'the ports of the mail clients are those of the recipe' => sub {
    require Provisioner::Recipe::mailrelay;
    no warnings 'once';
    is_deeply( \%Trog::RelayClient::CLIENT_PORTS, \%Provisioner::Recipe::mailrelay::CLIENT_PORTS, 'the client takes the ports that the relay registers for its guests' );
};

subtest 'mail release: a postfix that is not up does not stop a release' => sub {
    fresh_relay('mail');
    $client->redefine( reload => sub { die "$_[0] is not up\n" } );
    my ( undef, $warned, $status ) = client( 'mail', 'release', $DOMAIN );
    $client->unmock('reload');
    is( $status, 0, 'it exits 0' );
    like( $warned, qr/postfix[ ]is[ ]not[ ]up/, 'and warns, because postfix reads the tables when it starts' );
    like( $warned, qr/nginx[ ]is[ ]not[ ]up/,   'and goes on to nginx' );
};

subtest 'mail: it refuses what it cannot put in a table of postfix' => sub {
    fresh_relay('mail');
    my %bad = (
        'a registration without the address of the guest' => [ 'register', $DOMAIN ],
        'and one with a name for an address'              => [ 'register', $DOMAIN, 'web.test.test' ],
        'and one with more'                               => [ 'register', $DOMAIN, '192.0.2.10', 'extra' ],
        'and a domain in upper case'                      => [qw{register WEB.test 192.0.2.10}],
        'and a release with more than the domain'         => [ 'release',          $DOMAIN, 'extra' ],
        'and the mail clients of no name'                 => [ 'register-clients', $DOMAIN, $ADDRESS,        @PORTS ],
        'and of a name for the address'                   => [ 'register-clients', $DOMAIN, 'web.test.test', $DOMAIN,          @PORTS ],
        'and of a name in upper case'                     => [ 'register-clients', $DOMAIN, $ADDRESS,        'Mail.test.test', @PORTS ],
        'and of no port'                                  => [ 'register-clients', $DOMAIN, $ADDRESS,        $DOMAIN ],
    );
    foreach my $case ( sort keys %bad ) {
        like( exception { Trog::RelayClient::main( 'mail', @{ $bad{$case} } ) }, qr/\Ausage:/, $case );
    }
    like( exception { Trog::RelayClient::main( 'mail', 'register-clients', $DOMAIN, $ADDRESS, $DOMAIN, '--port', "25=10025:$DOMAIN" ) }, qr/one[ ]of[ ]465,[ ]993,[ ]995/, 'and of a port that postfix serves' );
    is_deeply( \@ran, [], 'and none of them ran anything' );
};

done_testing;
