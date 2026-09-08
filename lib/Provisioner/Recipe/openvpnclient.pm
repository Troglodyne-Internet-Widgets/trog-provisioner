package Provisioner::Recipe::openvpnclient;

#ABSTRACT: Connect the host to an OpenVPN server as a client.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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
machine running this tool.  The recipe rsyncs them to the provisioned host as
the C<transfer_user>, by address -- the same way the data recipe fetches a
domain's payload, and for the same reason: this runs before the guest's DNS is
any use.

Because the VPN tunnel is brought up during provisioning (not deferred to
postrun), any recipe that needs connectivity through the tunnel must run after
this one.  Recipe execution order is determined by the C<order:> key  set
this recipe's order to a value that sorts before any recipe depending on the
tunnel (e.g. C<order: A>).

=head3 Why nothing here is salvaged

C<cert_dir> on the hypervisor is where these certificates are kept, and they are
rsynced over the guest's copy on every run -- so a rebuilt guest needs nothing
brought back off the last one.

Which is the whole reason there is no C<remote_files> here.  Salvaging
F</etc/openvpn/client> would take a client key, which the fetch cannot read
anyway without a staged copy made for it, and put a second copy of it in the
domain directory and in every backup taken of that.  The hypervisor already
holds the only copy that has to exist.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {

        # It fetches its certificates over rsync, so it needs what does the
        # fetching as much as it needs openvpn.
        return qw{openvpn openssh-client rsync};
    }
    die "Unsupported packager";
}

sub args {
    return (
        required   => [qw{server cert_dir}],
        properties => {
            server   => { type => 'string' },
            cert_dir => { type => 'string' },
            port     => { type => 'integer', minimum => 1024,          default => 1194 },
            proto    => { type => 'string',  enum    => [qw{udp tcp}], default => 'udp' },
            cipher   => { type => 'string',  default => 'AES-256-GCM' },
        },
    );
}

sub template_files {
    my ($self) = @_;

    return (
        'openvpnclient.client.conf.tt' => 'client.conf',
    );
}

sub tests {
    return qw{openvpnclient.tt};
}

1;
