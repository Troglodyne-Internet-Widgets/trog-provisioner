package Trog::Local;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';
use parent 'Trog::Machine';

use Socket();

=head1 NAME

Trog::Local - this machine, as something a guest can fetch from

=head1 SYNOPSIS

    use Trog::Local();

    my $us = Trog::Local->new();

    $us->append_line( $us->authorized_keys, $pubkey );
    my $reachable = $us->transfer_ip( $hv->virbr_ip );

=head1 DESCRIPTION

The third machine in the toolkit, and the one that was never named.  L<Trog::HV>
is the hypervisor and L<Trog::Guest> is the VM; this is us, the machine running
the tool, and it is where a guest's payload actually lives.

It exists because a guest fetches that payload over ssh from whoever is holding
it, and until recently that was made to be the hypervisor: the domain directory
and the data directory were shipped there first so the guest had somewhere to
pull from.  They are not shipped anywhere now.  The guest reaches us instead,
which is one transfer fewer per provision and keeps the guest's private key off
the hypervisor.

Everything about being reachable -- the transfer user, its C<authorized_keys>,
the sshd port -- is L<Trog::Machine>'s and answers here without an SSH
connection, because C<is_local> is true and every one of those degrades to a
local filesystem or C<IPC::Run3> call.  What is added here is the one question
only this machine can answer: which of our addresses a guest can reach us at.

=head1 CLASS METHODS

=head2 new(%opts)

Takes nothing.  There is only one of us.

=cut

sub new {
    my ( $class, %opts ) = @_;
    return $class->SUPER::new(%opts);
}

=head1 IDENTITY

=head2 is_local

True, which is the whole point of this class.

=head2 describe

What to call us in an error message.

=cut

sub is_local { return 1 }
sub describe { return 'this machine' }

=head1 REACHABILITY

=head2 transfer_ip($towards)

The address of ours that a guest on C<$towards>'s network can reach us at, or
undef when there is no route to it at all.

C<$towards> is the hypervisor's address on its NAT bridge -- see
C<virbr_ip> in L<Trog::HV> -- because that is the network a guest is on before
it is on any other.

Asked of the kernel rather than worked out from a list of interfaces: a
connected UDP socket picks the source address the routing table would use for a
real connection, and reading it back is the same answer the guest's traffic will
get, including the case where we reach that network through a router rather than
by being on it.  Nothing is sent; C<connect> on a datagram socket only fixes the
peer.

The answer is not a promise that the guest can reach us -- routing is not
symmetric, and a firewall in between says nothing to a socket in here.  It is
what to try, and F<bin/preflight> is where that gets checked.

=cut

sub transfer_ip {
    my ( $self, $towards ) = @_;

    die "Which network a guest would reach us on has to be given\n"
      unless defined $towards && length $towards;

    my $peer = Socket::inet_aton($towards) or return undef;

    socket( my $sock, Socket::AF_INET(), Socket::SOCK_DGRAM(), 0 ) or return undef;

    # The port is arbitrary and never used.  Discard is as good as anything and
    # says plainly that nothing is going anywhere.
    connect( $sock, Socket::pack_sockaddr_in( 9, $peer ) ) or return undef;

    my $me = getsockname($sock) or return undef;
    close $sock;

    my ( undef, $address ) = Socket::unpack_sockaddr_in($me);
    return Socket::inet_ntoa($address);
}

=head1 SEE ALSO

L<Trog::Machine>, L<Trog::HV>, L<Trog::Guest>

=cut

1;
