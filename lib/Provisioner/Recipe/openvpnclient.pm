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
hypervisor.  The recipe rsyncs them to the provisioned host as the
C<transfer_user> from ipmap.cfg, over the hypervisor's NAT address -- the same
way the data recipe fetches a domain's payload, and for the same reason: this
runs before the guest's DNS is any use.

Because the VPN tunnel is brought up during provisioning (not deferred to
postrun), any recipe that needs connectivity through the tunnel must run after
this one.  Recipe execution order is determined by the C<order:> key  set
this recipe's order to a value that sorts before any recipe depending on the
tunnel (e.g. C<order: A>).

=head3 What the round trip is for, when cert_dir is the authority

The certificates come off the hypervisor on every run, so C<cert_dir> is where
they are kept and a rebuilt guest normally needs nothing salvaged at all.  What
the round trip answers is the run where that is not true: the copy taken off the
last guest goes back first, and the rsync then updates whatever C<cert_dir>
still has and leaves anything it has lost since where it is, rather than
starting a tunnel with a certificate missing.  On a guest that already has its
certificates C<restore_state> declines and nothing moves.

C<remote_files> names a staged copy at F</etc/openvpn/client-salvage> rather than
F</etc/openvpn/client>, for the reason the server recipe explains at more length:
the fetch is sftp as the admin user with no sudo, the real directory is root
owned with the keys at 0600, and naming it salvaged an empty directory without
saying so.  The staged copy is the admin user's and nobody else's, and the same
caveat applies -- the client key is readable by whoever holds that account, and
goes wherever the data directory goes.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {

        # It fetches its certificates off the hypervisor, so it needs what does
        # the fetching as much as it needs openvpn.
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

sub remote_files {
    return (
        # The staged copy, not /etc/openvpn/client -- which is root's, and comes
        # back empty from a fetch that is the admin user with no sudo.
        '/etc/openvpn/client-salvage/' => 'openvpn-client/',
    );
}

sub tests {
    return qw{openvpnclient.tt};
}

1;
