package Trog::Local;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::Machine';

use Socket();

=head1 NAME

Trog::Local - this machine, the one that a guest fetches its payload from

=head1 SYNOPSIS

    use Trog::Local();

    my $this_machine = Trog::Local->new();

    $this_machine->append_line( $this_machine->authorized_keys, $pubkey );
    my @reachable = $this_machine->transfer_ips( $guest_ip, $hv->virbr_ip );

=head1 DESCRIPTION

This is the machine that runs this tool.  L<Trog::HV> is the hypervisor, and
L<Trog::Guest> is the virtual machine.  This machine is the third one.  It holds
the payload of a guest: the domain directory and the data directory.  The guest
copies both from here.

L<Trog::Machine> supplies the transfer user, its C<authorized_keys> and the sshd
port.  Here, C<is_local> is true, so each of those is a local filesystem call or
an C<IPC::Run3> call, and no SSH connection opens.  This class adds one question
that only this machine can answer: at which of our addresses can a guest reach
us?

=head1 CLASS METHODS

=head2 new

Takes nothing and returns the one object for this machine.  Each call returns
the same object, because there is only one machine that we run on.

=cut

my $INSTANCE;

sub new {
    my ($class) = @_;
    return $INSTANCE //= $class->SUPER::new();
}

=head2 forget

Discards the object, so the next call to C<new> makes a new one.  Tests use it.
Returns 1.

=cut

sub forget {
    undef $INSTANCE;
    return 1;
}

=head1 IDENTITY

=head2 is_local

Returns 1.  This is the purpose of this class.

=head2 describe

Returns the name for this machine in an error message.

=cut

sub is_local { return 1 }
sub describe { return 'this machine' }

=head2 interactive

Returns 1 if a person can answer a prompt, and 0 if not.  A prompt that nobody
answers does not fail.  It stops the run until something else kills it.  So a
caller asks this before it prompts.

=cut

sub interactive {
    ## no critic (InputOutput::ProhibitInteractiveTest) -- whether there is anybody to ask is exactly what this decides
    return ( -t *STDIN && -t *STDOUT ) ? 1 : 0;
}

=head1 REACHABILITY

=head2 transfer_ips(@towards)

Returns each of our addresses that reaches a guest.  The list is in the order of
C<@towards>, with no repeats.  It is empty when no address in C<@towards> has a
route.  Dies when C<@towards> is empty.

C<@towards> holds the addresses of the guest.  A guest has more than one, on
different networks: its static address, and the lease that it gets from the NAT
bridge of the hypervisor.  From here, we cannot know which of these networks we
share with the guest.  A workstation can be on the bridge, on the static subnet,
on both, or reach one through a router.  We can also reach more than one, from a
different address each time.

It returns all of them, not only the first.  The guest fetches its payload over
one address, and we administer it over another.  Which one depends on whether we
are its hypervisor.  So the firewall on the guest must accept each address that
we can come from.  See C<admin_networks> in L<Provisioner::Recipe::ufw>.

The kernel supplies the answer, not a list of interfaces.  A connected UDP
socket gets the source address that the routing table uses for a real
connection.  The traffic of the guest gets the same answer.  This is also
correct when we reach a network through a router.  No packet goes out, because
C<connect> on a datagram socket only sets the peer.

This is also the limit.  Routing is not symmetric, and a socket here cannot see
a firewall between us and the guest.  So these are addresses to try, not a
promise that the guest can connect.  F<bin/preflight> makes sure of that.

=cut

sub transfer_ips {
    my ( $self, @towards ) = @_;

    die "Which addresses a guest would reach us on has to be given\n" unless @towards;

    my ( @ours, %seen );

    foreach my $towards (@towards) {
        next unless $towards;

        # The configuration writes each address of a domain as a CIDR, which
        # is a network and not something to connect to.
        ( my $peer = $towards ) =~ s{/\N*\z}{};

        my $packed = Socket::inet_aton($peer) or next;

        socket( my $sock, Socket::AF_INET(), Socket::SOCK_DGRAM(), 0 ) or next;

        # No packet goes to this port.  Port 9 is discard, which tells the
        # reader so.
        unless ( connect( $sock, Socket::pack_sockaddr_in( 9, $packed ) ) ) {
            close($sock) or die "Could not close the socket towards $peer: $!\n";
            next;
        }

        my $me = getsockname($sock);
        close($sock) or die "Could not close the socket towards $peer: $!\n";
        next unless $me;

        my ( undef, $address ) = Socket::unpack_sockaddr_in($me);
        my $ours = Socket::inet_ntoa($address);

        # One of our addresses can reach two addresses of the guest.  A
        # duplicate here becomes a duplicate firewall rule in before.rules.
        next if $seen{$ours}++;
        push( @ours, $ours );
    }

    return @ours;
}

=head2 transfer_ip(@towards)

Returns the first address from C<transfer_ips>, or undef when there is none.
The guest fetches its payload from this address.  It is one address, because
the rsync in the template names one.

Put the address of the guest first in C<@towards>.  On a remote hypervisor, we
connect to the guest with ssh at that address.  The answer is then the address
the guest fetches from, and also the address that it sees us come from.

=cut

sub transfer_ip {
    my ( $self, @towards ) = @_;
    my ($first) = $self->transfer_ips(@towards);
    return $first;
}

=head1 SEE ALSO

L<Trog::Machine>, L<Trog::HV>, L<Trog::Guest>

=cut

1;
