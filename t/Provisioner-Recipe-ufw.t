#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-ufw.t - one recipe to an address of a port, on the whole guest

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);
my %G = (
    domain      => 'ports.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'admin',
);

sub recipe {
    my ($name) = @_;
    return Provisioner::Cookbook->load( $name, distro => 'ubuntu' )->new(%PROV);
}

# What ufw is handed for these recipes on one domain, as bin/new_config resolves it.
sub listeners_of {
    my (%domain_conf) = @_;
    Provisioner::Cookbook->resolve_dependencies(
        modules       => [ sort keys %domain_conf ],
        domain_conf   => \%domain_conf,
        global_config => {%G},
        distro        => 'ubuntu',
        provisioner   => \%PROV,
        domain        => $G{domain},
    );
    return $domain_conf{ufw} // {};
}

subtest 'an address that two recipes claim is refused, and names them' => sub {
    my $ufw = recipe('ufw');

    ok( !exception { $ufw->validate( %G, listeners => { 3000 => { '127.0.0.1' => { gogs => 1 } }, 80 => { q{::} => { nginx => 1 } } } ) }, 'one recipe to each port is fine' );

    # The rows of the table in issue #250: what Linux refused, and what it let bind.
    ok(
        !exception { $ufw->validate( %G, listeners => { 3000 => { '127.0.0.1' => { gogs => 1 }, '203.0.113.8' => { grafana => 1 } } } ) },
        'loopback and an external address share a port, as the kernel lets them'
    );

    my $err = exception { $ufw->validate( %G, listeners => { 3000 => { '127.0.0.1' => { gogs => 1, grafana => 1 } } } ) };
    like( $err, qr{/listeners/3000/127\.0\.0\.1:[ ]Too[ ]many[ ]properties}, 'two on one address are refused, at the address' );
    like( $err, qr{\(gogs,[ ]grafana\)},                                     'naming both of them' );

    foreach my $every ( q{::}, '0.0.0.0' ) {
        $err = exception { $ufw->validate( %G, listeners => { 3000 => { '127.0.0.1' => { gogs => 1 }, $every => { grafana => 1 } } } ) };
        like( $err, qr{/listeners/3000:.*Too[ ]many[ ]properties}, "loopback and $every on one port are refused, at the port" );
        like( $err, qr{127\.0\.0\.1[ ]\{gogs\}},                   'naming loopback and the recipe on it' );
        like( $err, qr{\Q$every\E[ ]\{grafana\}},                  'and every address and the recipe on it' );
    }
    like(
        exception { $ufw->validate( %G, listeners => { 3000 => { '::1' => { gogs => 1 }, '0.0.0.0' => { grafana => 1 } } } ) },
        qr{/listeners/3000:.*Too[ ]many[ ]properties},
        'and every IPv4 address stands alone even beside IPv6 loopback, which is stricter than the kernel'
    );

    like( exception { $ufw->validate( %G, listeners => { 25 => { 465 => { mail => 1 } } } ) }, qr{/listeners/25:.*/propertyName/465}, 'an address that is a port is refused' );

    like( exception { $ufw->validate( %G, listeners => { '53/tcp' => { q{::} => { pdns => 1 } } } ) }, qr{/listeners}, 'a port is bare for tcp, as the claims write it, so /tcp is refused' );
    ok( !exception { $ufw->validate( %G, listeners => { '53/udp' => { q{::} => { pdns => 1 } }, 53 => { q{::} => { pdns => 1 } } } ) }, 'and tcp and udp on one number are two ports' );
};

subtest 'the claims of recipes on one domain meet in ufw' => sub {
    my $clash = listeners_of( gogs => {}, grafana => {} );
    is_deeply( $clash->{listeners}{3000}, { '127.0.0.1' => { gogs => 1, grafana => 1 } }, 'gogs and grafana both claim 127.0.0.1:3000' );
    like( exception { recipe('ufw')->validate( %G, %$clash ) }, qr{/listeners/3000/127\.0\.0\.1:.*\(gogs,[ ]grafana\)}, 'and ufw refuses it' );

    my $shared = listeners_of( gogs => {}, nginxdirindex => {} );
    is_deeply( $shared->{listeners}{80}, { q{::} => { nginx => 1 } }, 'two recipes behind nginx leave 80 to nginx alone' );
    ok( !exception { recipe('ufw')->validate( %G, %$shared ) }, 'which ufw accepts' );
};

subtest "every recipe's claims are ones that ufw accepts" => sub {
    my $ufw = recipe('ufw');
    foreach my $name ( Provisioner::Cookbook->names ) {
        my $class = Provisioner::Cookbook->load( $name, distro => 'ubuntu' );
        my %listeners;
        is( exception { %listeners = $class->claims(%G) },                undef, "$name claims only ports, with an address or without" ) or next;
        is( exception { $ufw->validate( %G, listeners => \%listeners ) }, undef, "and ufw accepts what $name claims" );
    }
};

done_testing();
