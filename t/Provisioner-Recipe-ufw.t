#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-ufw.t - one recipe to a port, on the whole guest

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

subtest 'a port that two recipes claim is refused, and names them' => sub {
    my $ufw = recipe('ufw');

    ok( !exception { $ufw->validate( %G, listeners => { 3000 => { gogs => 1 }, 80 => { nginx => 1 } } ) }, 'one recipe to each port is fine' );

    my $err = exception { $ufw->validate( %G, listeners => { 3000 => { gogs => 1, grafana => 1 } } ) };
    like( $err, qr{/listeners/3000:[ ]Too[ ]many[ ]properties}, 'two on one port are refused, at the port' );
    like( $err, qr{\(gogs,[ ]grafana\)},                        'naming both of them' );

    like( exception { $ufw->validate( %G, listeners => { '53/tcp' => { pdns => 1 } } ) }, qr{/listeners}, 'a port is bare for tcp, as the claims write it, so /tcp is refused' );
    ok( !exception { $ufw->validate( %G, listeners => { '53/udp' => { pdns => 1 }, 53 => { pdns => 1 } } ) }, 'and tcp and udp on one number are two ports' );
};

subtest 'the claims of recipes on one domain meet in ufw' => sub {
    my $clash = listeners_of( gogs => {}, grafana => {} );
    is_deeply( $clash->{listeners}{3000}, { gogs => 1, grafana => 1 }, 'gogs and grafana both claim 3000' );
    like( exception { recipe('ufw')->validate( %G, %$clash ) }, qr{/listeners/3000:.*\(gogs,[ ]grafana\)}, 'and ufw refuses it' );

    my $shared = listeners_of( gogs => {}, nginxdirindex => {} );
    is_deeply( $shared->{listeners}{80}, { nginx => 1 }, 'two recipes behind nginx leave 80 to nginx alone' );
    ok( !exception { recipe('ufw')->validate( %G, %$shared ) }, 'which ufw accepts' );
};

subtest "every recipe's claims are ports as ufw writes them" => sub {
    foreach my $name ( Provisioner::Cookbook->names ) {
        my $class  = Provisioner::Cookbook->load( $name, distro => 'ubuntu' );
        my %limits = $class->rate_limits(%G);
        my @bad    = grep { !m{\A\d+(?:/(?:tcp|udp))?\z} } keys(%limits), $class->listens(%G);
        is_deeply( \@bad, [], "$name claims only ports" );
    }
};

done_testing();
