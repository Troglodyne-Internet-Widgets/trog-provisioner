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
            redirect_gateway: false

=head2 DESCRIPTION

Sets up an OpenVPN server using easy-rsa for PKI management.

Generates a server CA, server certificate/key, and DH parameters under
/etc/openvpn/easy-rsa/. The server listens on the configured port/proto and
pushes a route for the VPN subnet to clients.

If the ufw recipe is also enabled, a UFW application rule for OpenVPN will be
installed automatically.

=head3 What it takes to route a client's traffic anywhere

Three things, and two of them are not enough.

C<net.ipv4.ip_forward> is turned on, and a MASQUERADE rule sends the VPN subnet
out of the guest wearing the guest's address.  Neither is what decides whether a
forwarded packet lives: it meets the filter FORWARD chain first, and Ubuntu
ships C</etc/default/ufw> with C<DEFAULT_FORWARD_POLICY="DROP">.  The third
thing is therefore an accept for the subnet in C<ufw-before-forward>, without
which the MASQUERADE rule is correct and unreachable -- and a client that
connects loses its connectivity rather than gaining a route, since
C<redirect-gateway> has meanwhile told it to send everything here.

C<setup-masquerade> writes both halves.  The accept names the VPN subnet rather
than setting C<DEFAULT_FORWARD_POLICY="ACCEPT">, which would make the guest
willing to route anything for anybody.

C<interface> says which interface to masquerade out of, and is not decided here:
the name depends on how the guest booted -- C<ens3>, C<ens4>, C<enp1s0> -- and a
wrong one writes a rule that matches nothing and reports success.  Omitted, the
guest is asked which interface carries its default route at the moment the rule
is written.

C<redirect_gateway> tells clients to route everything through the tunnel, not
just requests to hosts on the VPN.
Default off.

=head3 The PKI is the part that cannot be made again

Everything else here is regenerated on demand; a new CA is not the same CA.
Issue it a second time and every client certificate ever signed by the first one
stops being trusted, and the clients holding them are not here to be told.  So
the PKI makes the round trip, and the fragment puts it back before easyrsa is
asked for anything.

The guard on PKI generation is not enough on its own.  It only fires when the
old pki is still on the disk, which is a re-provision; a guest rebuilt from
nothing has an empty disk, sails past it and signs itself a new CA.  Restoring
first is what closes that.

What C<remote_files> names is a staged copy the fragment leaves at
F</etc/openvpn/pki-salvage>, not the pki itself.  The fetch is an sftp session as
the admin user with no sudo and easy-rsa keeps its pki at 0700 root with the keys
at 0600, so naming the real thing came back with an empty directory and no
complaint -- the salvage looked like it was working for as long as nobody
rebuilt a guest.  The staged copy belongs to the admin user and is readable by
nobody else, which is the same trade the mail recipe makes to salvage the DKIM
keys: the CA private key is now readable by whoever holds the admin account, and
it travels into the data directory and into whatever backup is taken of that.
That is the price of a VPN that survives its own guest, and it is worth saying
out loud because the alternative is not free either.

The copy is only as new as the last provision, so a client certificate issued by
hand afterwards is not in it until the next one runs.  The CA it was signed with
is, which is what keeps the certificate working.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{openvpn easy-rsa};
    }
    die "Unsupported packager";
}

sub rate_limits {
    my ( $self, %opts ) = @_;

    # Called before validation, so the schema default is not in %opts yet; it
    # has to be repeated rather than read.  A client opens one tunnel and keeps
    # it, so anything opening hundreds a second is not a client.
    return ( ( $opts{port} // 1194 ) => 256 );
}

sub args {
    return (
        properties => {
            port  => { type => 'integer', minimum => 1024,          default => 1194 },
            proto => { type => 'string',  enum    => [qw{udp tcp}], default => 'udp' },

            # An address is a string with a format, not a type of its own.  As a
            # type these were never checked -- the validator has no
            # _validate_type_ipv4 and never reached one, because the fields were
            # always absent until defaults started being applied.
            subnet  => { type => 'string', format  => 'ipv4', default => '10.8.0.0' },
            netmask => { type => 'string', format  => 'ipv4', default => '255.255.255.0' },
            cipher  => { type => 'string', default => 'AES-256-GCM' },
            dns     => { type => 'array',  items   => { type => 'string' } },

            # Which interface VPN traffic is masqueraded out of.  No default,
            # because the answer is a fact about the guest and not one this
            # machine can know -- these guests come up as ens3, ens4 or enp1s0
            # depending on how they booted, and naming the wrong one writes a
            # rule that matches nothing.  Left unset, setup-masquerade asks the
            # guest which interface its default route leaves by.
            interface => { type => 'string' },

            # Whether the server tells clients to send everything down the
            # tunnel.  Pushed at connect time, so whatever this says takes
            # effect on every deployed client the next time it reconnects --
            # turning it on is therefore a change to machines nobody is
            # touching, which is why it is off unless a domain asks.
            redirect_gateway => { type => 'boolean', default => 0 },
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

        # The ufw application profile for the port and protocol this domain
        # configured.  It lived under ufw, which is handed rate_limits and
        # nothing else -- so it named two variables it never had.
        'openvpn.ufw.conf.tt' => 'openvpn_ufw.conf',
    );
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # The certificate authority.  A rebuilt guest that makes a new one is a
    # server every existing client refuses to talk to, so this has to arrive
    # before easyrsa is asked whether it needs to build one.
    return ( '/etc/openvpn/easy-rsa/pki' => { from => "$install_dir/$domain/openvpn/pki", owner => 'root:root' } );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # The staged copy of the PKI (CA, server cert/key, DH params, TLS auth
        # key, client certs), rather than the pki itself: the fetch is sftp as
        # the admin user with no sudo, and easy-rsa keeps the original where he
        # cannot read a byte of it.  The fragment stages this one and restores
        # what came down from it.
        '/etc/openvpn/pki-salvage/' => 'openvpn/pki/',
    );
}

sub tests {
    return qw{openvpn.tt};
}

1;
