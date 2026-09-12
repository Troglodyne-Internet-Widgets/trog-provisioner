#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-openvpnclient.t - one tunnel for each domain, and what names it

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();

use FindBin::libs;

use Provisioner::Cookbook();
use Provisioner::Recipe::openvpnclient();

my %BASE = (
    server        => 'vpn.test.test',
    cert_dir      => '/opt/vpn-certs/first',
    install_dir   => '/opt/domains',
    script_dir    => '/root/bin',
    admin_user    => 'doge',
    transfer_user => 'doge',
    transfer_ip   => '192.168.1.49',
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
    like( $fragment, qr{wait_for_iface \Q$opts{device}\E},        'the wait is on the interface this domain was given' );

    # tun0 is whichever tunnel came up first, which on a guest holding two is
    # not necessarily this one.
    unlike( $fragment, qr{wait_for_iface tun0\b}, 'rather than on whichever came up first' );
};

subtest 'the configuration points at what belongs to this domain' => sub {
    my $recipe = fresh();
    my $dir    = tempdir( CLEANUP => 1 );
    my %vars   = ( %BASE, domain => 'first.test' );
    my %opts   = $recipe->validate(%vars);

    $recipe->generate_files( $dir, %vars );
    my $conf = File::Slurper::read_text("$dir/client.conf");

    like( $conf, qr/^dev \Q$opts{device}\E$/m,                               'the device is named rather than left to openvpn' );
    like( $conf, qr{^ca\s+/etc/openvpn/client/first[.]test/ca[.]crt$}m,      'the authority is this domain copy' );
    like( $conf, qr{^key\s+/etc/openvpn/client/first[.]test/client[.]key$}m, 'and so is the key' );
    like( $conf, qr{openvpn-client-first[.]test[.]log},                      'and the log cannot collide with another tunnel' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
