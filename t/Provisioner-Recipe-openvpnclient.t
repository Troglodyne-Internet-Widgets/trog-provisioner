#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-openvpnclient.t - one tunnel for each domain, and what names it

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use MIME::Base64();
use Fcntl();

use FindBin::libs;

use Provisioner::Cookbook();

my %BASE = (
    server        => 'vpn.test.test',
    cert_dir      => '/opt/vpn-certs/first',
    install_dir   => '/opt/domains',
    script_dir    => '/root/bin',
    admin_user    => 'someadmin',
    transfer_user => 'someadmin',
    transfer_ip   => '192.0.2.49',
    transfer_port => 22,
);

# A recipe per call: validated() is memoised on the object and answers the first
# set of arguments it was given, so two domains need two of them.
sub fresh {
    return Provisioner::Cookbook->load( 'openvpnclient', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

subtest 'each domain gets an interface of its own' => sub {
    my %first  = fresh()->validate( %BASE, domain => 'first.test' );
    my %second = fresh()->validate( %BASE, domain => 'second.test' );

    isnt( $first{device}, $second{device}, 'two domains do not land on one interface' );

    foreach my $device ( $first{device}, $second{device} ) {
        like( $device, qr/\Atun/, "$device is a tun device" );

        # IFNAMSIZ, less the terminator.  A domain name is routinely longer than
        # this, which is why the name is hashed rather than spelled out.
        cmp_ok( length $device, '<=', 15, "$device is short enough for the kernel to take" );
    }

    my %again = fresh()->validate( %BASE, domain => 'first.test' );
    is( $again{device}, $first{device}, 'and a rebuild comes back to the interface it had' );
};

subtest 'a domain that names its own keeps it' => sub {
    my %opts = fresh()->validate( %BASE, domain => 'first.test', device => 'tun-vpn1' );
    is( $opts{device}, 'tun-vpn1', 'the derived name gives way to the configured one' );
};

subtest 'the fragment names the domain throughout' => sub {
    my $recipe   = fresh();
    my %vars     = ( %BASE, domain => 'first.test' );
    my %opts     = $recipe->validate(%vars);
    my $fragment = $recipe->render(%vars);

    like( $fragment, qr{openvpn-client\@first[.]test},            'the unit is instanced on the domain' );
    like( $fragment, qr{/etc/openvpn/client/first[.]test[.]conf}, 'the configuration is where that instance reads it' );
    like( $fragment, qr{/etc/openvpn/client/first[.]test/},       'and the certificates land in a directory of its own' );
    like( $fragment, qr{wait_for_iface[ ]\Q$opts{device}\E},      'the wait is on the interface this domain was given' );

    # tun0 is whichever tunnel came up first, which on a guest holding two is
    # not necessarily this one.
    unlike( $fragment, qr{wait_for_iface[ ]tun0\b}, 'rather than on whichever came up first' );
};

subtest 'the configuration points at what belongs to this domain' => sub {
    my $recipe = fresh();
    my $dir    = tempdir( CLEANUP => 1 );
    my %vars   = ( %BASE, domain => 'first.test' );
    my %opts   = $recipe->validate(%vars);

    $recipe->generate_files( $dir, %vars );
    my $conf = File::Slurper::read_text("$dir/client.conf");

    like( $conf, qr/^dev[ ]\Q$opts{device}\E$/m,                             'the device is named rather than left to openvpn' );
    like( $conf, qr{^ca\s+/etc/openvpn/client/first[.]test/ca[.]crt$}m,      'the authority is this domain copy' );
    like( $conf, qr{^key\s+/etc/openvpn/client/first[.]test/client[.]key$}m, 'and so is the key' );
    like( $conf, qr{openvpn-client-first[.]test[.]log},                      'and the log cannot collide with another tunnel' );
};

my %POOL   = ( ip_pool                                                                      => { cidr => '192.0.2.0/24', bins => { vpnclients => { cidr => '10.8.0.128/25', via => 'vpn.test.test' } } } );
my %ISSUED = ( ( map { $_ => $BASE{$_} } grep { $_ ne 'cert_dir' } keys %BASE ), issue_from => 'vpn.test.test', %POOL );

subtest 'issue_from or cert_dir, and not both' => sub {
    is( exception { fresh()->validate( %ISSUED, domain => 'first.test' ) }, undef, 'issue_from alone is enough' );
    ok( exception { fresh()->validate( %ISSUED, cert_dir => '/bogus', domain => 'first.test' ) }, 'and both is refused' );
    my %neither = %ISSUED;
    delete $neither{issue_from};
    ok( exception { fresh()->validate( %neither, domain => 'first.test' ) }, 'and so is neither' );
    ok( exception { fresh()->validate( %ISSUED, server => 'vpn.test.test; reboot', domain => 'first.test' ) }, 'a server that is not a name is refused, because it goes into a command on the server' );
};

subtest 'an issued configuration comes from the bin that the server routes' => sub {
    my %opts = fresh()->validate( %ISSUED, domain => 'first.test' );
    is_deeply( $opts{address_blocks}, ['10.8.0.128/25'], 'the guest test knows which networks the address must be in' );

    my %other = ( ip_pool => { cidr => '192.0.2.0/24', bins => { vpnclients => { cidr => '10.8.0.128/25', via => 'other.test.test' } } } );
    like( exception { fresh()->validate( %ISSUED, %other, domain => 'first.test' ) }, qr/via[ ]is[ ]vpn[.]test[.]test, .* none/, 'and with no bin for the server, the build stops here' );

    my $fragment = fresh()->render( %ISSUED, domain => 'first.test' );
    cmp_ok( index( $fragment, 'base64 -d /etc/openvpn/client/first.test/issued.ovpn.b64' ), '>=', 0, 'the fragment decodes what the server issued' );
    like( $fragment, qr{umask[ ]077}, 'into files that nobody else can read' );
    unlike( $fragment, qr/rsync/, 'and fetches nothing from this machine' );
};

subtest 'the fragment splits the issued configuration into the four files' => sub {
    my $fragment = fresh()->render( %ISSUED, domain => 'first.test' );
    my ($line) = $fragment =~ m{^(\s*umask[ ]077[ ]\N+)$}m or return fail('no line that decodes the configuration');

    # The line as make runs it: $$ is one dollar, and the guest path is this one.
    my $dir = tempdir( CLEANUP => 1 );
    ( my $shell = $line ) =~ s/\$\$/\$/g;
    $shell =~ s{/etc/openvpn/client/first[.]test}{$dir}g;

    my $ovpn = join( "\n", 'client', 'dev tun', '<ca>', 'THE CA', '</ca>', '<cert>', 'THE CERT', '</cert>', '<key>', 'THE KEY', 'TWO LINES', '</key>', '<tls-auth>', 'THE TA', '</tls-auth>', q{} );
    File::Slurper::Temp::write_text( "$dir/issued.ovpn.b64", MIME::Base64::encode_base64( $ovpn, q{} ) );

    is( system( 'bash', '-c', $shell ),                                     0,                      'the line runs' ) or diag $shell;
    is( File::Slurper::read_text("$dir/ca.crt"),                            "THE CA\n",             'the CA lands in ca.crt' );
    is( File::Slurper::read_text("$dir/client.crt"),                        "THE CERT\n",           'the certificate in client.crt' );
    is( File::Slurper::read_text("$dir/client.key"),                        "THE KEY\nTWO LINES\n", 'the whole key in client.key' );
    is( File::Slurper::read_text("$dir/ta.key"),                            "THE TA\n",             'and the tls-auth key in ta.key' );
    is( sprintf( '%04o', Fcntl::S_IMODE( ( stat "$dir/client.key" )[2] ) ), '0600',                 'which nobody else can read from the start' );
};

subtest 'guest_secrets asks the server for the configuration, with an address from the bin' => sub {
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    my $cook = Test::MockModule->new('Provisioner::Cookbook');
    my @asked;
    $pool->redefine( assign        => sub { push @asked, [@_]; return '10.8.0.129' } );
    $cook->redefine( global_config => sub { return {%POOL} } );

    my %secrets = fresh()->guest_secrets( '/opt/domains', 'first.test', %ISSUED );
    is_deeply( \@asked, [ [ 'first.test', $POOL{ip_pool}, 'vpnclients' ] ], 'the address comes from the bin that names the server' );
    is_deeply(
        \%secrets,
        {
            '/etc/openvpn/client/first.test/issued.ovpn.b64' => {
                issue => { guest => 'vpn.test.test', command => '/usr/local/sbin/openvpn-client-config --address 10.8.0.129 first.test vpn.test.test | base64 -w0' },
                owner => 'root:root',
                mode  => '0600',
            }
        },
        'and the server issues the configuration with that address, on one line'
    );

    is_deeply( { fresh()->guest_secrets( '/opt/domains', 'first.test', %BASE ) }, {}, 'a domain with a cert_dir asks for nothing' );
};

subtest 'bin/destroy knows where to revoke' => sub {
    my $cook = Test::MockModule->new('Provisioner::Cookbook');
    $cook->redefine( domain_config => sub { return $_[1] eq 'first.test' ? { openvpnclient => { issue_from => 'vpn.test.test' } } : { openvpnclient => { cert_dir => '/bogus' } } } );

    is( fresh()->issuer_of('first.test'),      'vpn.test.test',                                    'a domain with issue_from is revoked on that server' );
    is( fresh()->issuer_of('second.test'),     undef,                                              'and one with a cert_dir nowhere' );
    is( fresh()->revoke_command('first.test'), '/usr/local/sbin/openvpn-revoke-client first.test', 'by the script that also frees the address' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
