#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-openvpn.t - the CIDR blocks that the openvpn recipe takes

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Copy();
use File::Path();
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

# A recipe per call: validated() is memoised on the object.
sub fresh {
    return Provisioner::Cookbook->load( 'openvpn', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

my %BASE = ( domain => 'vpn.test.test', admin_user => 'someadmin' );

subtest 'routes: a block must be an IPv4 address and a prefix of 0 to 32' => sub {
    foreach my $good (qw{192.0.2.0/24 192.0.2.7/32 0.0.0.0/0 192.0.2.5/24}) {
        is( exception { fresh()->validate( %BASE, routes => [$good] ) }, undef, "$good is taken" );
    }

    foreach my $bad (qw{999.0.2.0/24 192.0.2.0/99 192.0.2.0/33 1234.0.2.0/24 192.0.2.0}) {
        like( exception { fresh()->validate( %BASE, routes => [ '192.0.2.0/24', $bad ] ) }, qr/\Q$bad\E.*not[ ]an[ ]IPv4[ ]CIDR[ ]block|not[ ]valid/, "$bad is refused" );
    }
};

subtest 'openvpn-client-config --address auto: the server chooses a free address of its bin, and keeps the one a client has' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my %pool = ( ip_pool => { bins => { vpnclients => { cidr => '10.8.0.252/30', via => 'vpn.test.test' } } } );

    my $script = "$dir/openvpn-client-config";
    File::Slurper::Temp::write_text( $script, fresh()->render_file( 'files/openvpn.client-config.tt', %BASE, %pool ) );

    # A PKI of one self-signed certificate, which serves as each of them: the
    # script only prints what it finds.
    my $pki = "$dir/easy-rsa/pki";
    File::Path::make_path( map { "$pki/$_" } qw{issued private} );
    IPC::Run3::run3( [ qw{openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=test.test -keyout}, "$pki/private/ca.key", '-out', "$pki/ca.crt" ], \undef, \undef, \undef );
    File::Slurper::Temp::write_text( "$pki/ta.key", "THE TA\n" );
    foreach my $client (qw{one.test.test two.test.test three.test.test}) {
        File::Copy::copy( "$pki/ca.crt",         "$pki/issued/$client.crt" )  or die "Could not copy the certificate: $!";
        File::Copy::copy( "$pki/private/ca.key", "$pki/private/$client.key" ) or die "Could not copy the key: $!";
    }

    my $ccd = "$dir/ccd";
    local @ENV{qw{OPENVPN_EASYRSA_DIR OPENVPN_CCD_DIR}} = ( "$dir/easy-rsa", $ccd );
    my $issue = sub (@args) {
        IPC::Run3::run3( [ 'bash', $script, @args ], \undef, \my $out, \my $err );
        return ( $? >> 8, $err );
    };
    my $pushed = sub ($client) { return ( File::Slurper::read_text("$ccd/$client") =~ m/\Aifconfig-push[ ](\S+)[ ]/ )[0] };

    is( ( $issue->(qw{--address auto one.test.test}) )[0], 0,            'a client gets an address' );
    is( $pushed->('one.test.test'),                        '10.8.0.253', 'the first of the bin, after the network' );
    $issue->(qw{--address auto two.test.test});
    is( $pushed->('two.test.test'), '10.8.0.254', 'the next client the next one' );
    $issue->(qw{--address auto one.test.test});
    is( $pushed->('one.test.test'), '10.8.0.253', 'and a client issued again keeps its address' );

    my ( $code, $err ) = $issue->(qw{--address auto three.test.test});
    isnt( $code, 0, 'a full bin refuses, and its network and broadcast addresses are not given out' );
    like( $err, qr/no[ ]address[ ]is[ ]free/, 'and says so' );
    ok( !-e "$ccd/three.test.test", 'and gives the client nothing' );

    ( $code, $err ) = $issue->(qw{--address 10.8.0.253 three.test.test});
    like( $err, qr/one[.]test[.]test[ ]already[ ]has[ ]10[.]8[.]0[.]253/, 'an address that a client has is still refused by hand' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
