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

    my $this_machine = Trog::Local->new();

    $this_machine->append_line( $this_machine->authorized_keys, $pubkey );
    my $reachable = $this_machine->transfer_ip( $guest_ip, $hv->virbr_ip );

=head1 DESCRIPTION

The machine running this tool.  L<Trog::HV> is the hypervisor and L<Trog::Guest>
is the VM; this is the third one in the conversation, and it is where a guest's
payload lives -- the domain directory it scps its tarball out of, and the data
directory it rsyncs.

Everything about being reachable -- the transfer user, its C<authorized_keys>,
the sshd port -- is L<Trog::Machine>'s, and answers here without an SSH
connection because C<is_local> is true and each of those degrades to a local
filesystem or C<IPC::Run3> call.  What is added here is the question only this
machine can answer: which of our addresses a guest can reach us at.

=head1 CLASS METHODS

=head2 new

A singleton, and takes nothing.  There is one machine we are running on, and
everything that asks for it wants the same one.

=head2 forget

Drop the singleton, so the next C<new> builds a fresh one.  For tests.

=cut

my $INSTANCE;

sub new {
    my ($class) = @_;
    return $INSTANCE //= $class->SUPER::new();
}

sub forget {
    undef $INSTANCE;
    return 1;
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

=head2 transfer_ip(@towards)

The address of ours that a guest can reach us at, or undef when none of
C<@towards> routes anywhere.

C<@towards> is the addresses that guest will have, best first.  A guest has more
than one and they are on different networks: the static address it is
configured with, and the lease it takes off the hypervisor's NAT bridge.  Which
of them we share with it is not knowable from here -- a workstation may sit on
the bridge, on the static subnet, on both, or reach one through a router -- so
each is tried in turn and the first that routes decides.

Order matters, and the guest's own address is the one to put first: it is the
address we ssh to, so answering for that network gives one address that is both
where the guest fetches from and where it sees us coming from.

Asked of the kernel rather than worked out from a list of interfaces.  A
connected UDP socket picks the source address the routing table would use for a
real connection, which is the same answer the guest's traffic will get and is
right for the case where we reach a network through a router rather than by
being on it.  Nothing is sent; C<connect> on a datagram socket only fixes the
peer.

Which is also its limit.  Routing is not symmetric and a firewall in between
says nothing to a socket in here, so this is what to try rather than a promise
that the guest will get through.  F<bin/preflight> is where that is checked.

=cut

sub transfer_ip {
    my ( $self, @towards ) = @_;

    die "Which addresses a guest would reach us on has to be given\n" unless @towards;

    foreach my $towards (@towards) {
        next unless defined $towards && length $towards;

        # A cidr is a network rather than something to connect to, and the
        # addresses a domain is configured with are written as one.
        ( my $peer = $towards ) =~ s{/.*\z}{};

        my $packed = Socket::inet_aton($peer) or next;

        socket( my $sock, Socket::AF_INET(), Socket::SOCK_DGRAM(), 0 ) or next;

        # The port is arbitrary and never used.  Discard is as good as anything
        # and says plainly that nothing is going anywhere.
        unless ( connect( $sock, Socket::pack_sockaddr_in( 9, $packed ) ) ) {
            close $sock;
            next;
        }

        my $me = getsockname($sock);
        close $sock;
        next unless $me;

        my ( undef, $address ) = Socket::unpack_sockaddr_in($me);
        return Socket::inet_ntoa($address);
    }

    return undef;
}

=head1 SEE ALSO

L<Trog::Machine>, L<Trog::HV>, L<Trog::Guest>

=cut

1;
