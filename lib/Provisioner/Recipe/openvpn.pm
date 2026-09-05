package Provisioner::Recipe::openvpn;

#ABSTRACT: Set up an OpenVPN server with an easy-rsa PKI.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use Socket qw{inet_aton};

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::openvpn

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        openvpn:
            port: 1194
            proto: udp
            subnet: 10.8.0.0
            netmask: 255.255.255.0
            cipher: AES-256-GCM
            # dns is optional; if omitted, no DNS servers are pushed to clients
            interface: eth0

=head2 DESCRIPTION

Sets up an OpenVPN server using easy-rsa for PKI management.

Generates a server CA, server certificate/key, and DH parameters under
/etc/openvpn/easy-rsa/. The server listens on the configured port/proto and
pushes a route for the VPN subnet to clients.

If the ufw recipe is also enabled, a UFW application rule for OpenVPN will be
installed automatically.

The interface option is used to set up NAT (masquerade) so VPN clients can
reach the internet. If omitted, NAT is not configured.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{openvpn easy-rsa};
    }
    die "Unsupported packager";
}

sub rate_limits {
    my ($self, %opts) = @_;
    # Called before validation, so the schema default is not in %opts yet; it
    # has to be repeated rather than read.  A client opens one tunnel and keeps
    # it, so anything opening hundreds a second is not a client.
    return ( ( $opts{port} // 1194 ) => 256 );
}

sub args {
    return (
        properties => {
            port      => { type => 'integer', minimum => 1024, default => 1194 },
            proto     => { type => 'string', enum => [qw{udp tcp}], default => 'udp' },
            # An address is a string with a format, not a type of its own.  As a
            # type these were never checked -- the validator has no
            # _validate_type_ipv4 and never reached one, because the fields were
            # always absent until defaults started being applied.
            subnet    => { type => 'string', format => 'ipv4', default => '10.8.0.0' },
            netmask   => { type => 'string', format => 'ipv4', default => '255.255.255.0' },
            cipher    => { type => 'string', default => 'AES-256-GCM' },
            dns       => { type => 'array', items => { type => 'string' } },
            interface => { type => 'string' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;
    $opts{cidr} = _netmask_to_cidr( $opts{netmask} );
    return %opts;
}

# Convert a dotted-quad netmask (e.g. 255.255.255.0) into a CIDR prefix length
# (e.g. 24). Used to render iptables/MASQUERADE source CIDRs.
sub _netmask_to_cidr {
    my ($mask) = @_;

    # Guard the shape before inet_aton(), which would otherwise resolve a
    # non-dotted-quad as a hostname.
    return 0 unless $mask && $mask =~ m{^\d{1,3}(?:\.\d{1,3}){3}$};
    my $packed = inet_aton($mask) or return 0;
    return unpack( '%32b*', $packed );
}

sub template_files {
    my ($self) = @_;

    return (
        'openvpn.server.conf.tt' => 'server.conf',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # PKI (CA, server cert/key, DH params, TLS auth key, client certs)
        '/etc/openvpn/easy-rsa/pki/' => 'openvpn/pki/',
    );
}

sub tests {
    return qw{openvpn.tt};
}

1;
