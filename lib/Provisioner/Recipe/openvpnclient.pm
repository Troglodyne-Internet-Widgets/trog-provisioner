package Provisioner::Recipe::openvpnclient;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::openvpnclient

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        openvpnclient:
            order: A
            server: vpn.example.com
            cert_dir: /opt/vpn-certs/somedomain
            port: 1194
            proto: udp
            cipher: AES-256-GCM

=head2 DESCRIPTION

Connects this host to an OpenVPN server as a client.

Client certificates (ca.crt, client.crt, client.key, ta.key) must be
pre-generated on the VPN server via easy-rsa and placed in cert_dir on the
hypervisor.  The recipe rsyncs them to the provisioned host.

Because the VPN tunnel is brought up during provisioning (not deferred to
postrun), any recipe that needs connectivity through the tunnel must run after
this one.  Recipe execution order is determined by the C<order:> key — set
this recipe's order to a value that sorts before any recipe depending on the
tunnel (e.g. C<order: A>).

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{openvpn};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    die "openvpnclient requires 'server'" unless $opts{server};
    die "openvpnclient requires 'cert_dir'" unless $opts{cert_dir};

    $opts{port}   //= 1194;
    $opts{proto}  //= 'udp';
    $opts{cipher} //= 'AES-256-GCM';

    die "proto must be 'udp' or 'tcp'" unless $opts{proto} =~ /^(udp|tcp)$/;
    die "port must be numeric"         unless $opts{port}  =~ /^\d+$/;

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'openvpnclient.client.conf.tt' => 'client.conf',
    );
}

sub remote_files {
    return (
        '/etc/openvpn/client/' => 'openvpn-client/',
    );
}

1;
