package Trog::Local;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::Machine';

use Socket();
use Time::HiRes qw{alarm};
use File::Which();
use IPC::Run3();
use Fcntl qw{S_ISREG};
use File::Temp();
use Trog::Utils();
use Data::Validate::Domain();

=head1 NAME

Trog::Local - this machine, the one that a guest fetches its payload from

=head1 SYNOPSIS

    use Trog::Local();

    my $this_machine = Trog::Local->new();

    $this_machine->authorize_guest_key( $domain, $domain_dir, $pubkey );
    my @reachable = $this_machine->transfer_ips( $guest_ip, $hv->virbr_ip );

=head1 DESCRIPTION

This is the machine that runs this tool.  L<Trog::HV> is the hypervisor, and
L<Trog::Guest> is the virtual machine.  This machine is the third one.  It holds
the payload of a guest: the domain directory and the data directory.  The guest
copies both from here, through the rsync modules that its key is restricted to.
See L<Provisioner::Recipe::data/What the key of the guest reaches>.

L<Trog::Machine> supplies the transfer user, its C<authorized_keys> and the sshd
port.  Here, C<is_local> is true, so each of those is a local filesystem call or
an C<IPC::Run3> call, and no SSH connection opens.  This class adds two questions
that only this machine can answer: at which of our addresses can a guest reach
us, and can bubblewrap make the sandbox that its fetches run in?

=head1 CLASS METHODS

=head2 new

Takes nothing and returns the one object for this machine.  Each call returns
the same object, because there is only one machine that we run on.

=cut

sub new {
    my ($class) = @_;
    return Trog::Local->kept() // Trog::Local->keep( $class->SUPER::new() );
}

=head2 forget

Discards the object, as L<Trog::Machine/keep($object), kept, forget> says, so
the next call to C<new> makes a new one.  Tests use it.  Returns 1.

=cut

=head1 IDENTITY

=head2 is_local

Returns 1.  This is the purpose of this class.

=head2 describe

Returns the name for this machine in an error message.

=cut

sub is_local { return 1 }
sub describe { return 'this machine' }

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

=head2 holds_address($address)

Whether C<$address> is an address of this machine.

It asks the kernel by binding a socket to it, which succeeds only for an
address this machine holds, rather than by reading a list of interfaces.  An
address behind a gateway is not one of ours however much it looks like it.

=cut

sub holds_address {
    my ( $class, $address ) = @_;

    my $packed = Socket::inet_aton($address)                          or return 0;
    socket( my $socket, Socket::PF_INET(), Socket::SOCK_STREAM(), 0 ) or return 0;

    my $ours = bind( $socket, Socket::pack_sockaddr_in( 0, $packed ) ) ? 1 : 0;

    # Nothing was written to it, so a failed close has nothing to lose.
    close($socket) or undef;

    return $ours;
}

=head2 answers_on($address, $port)

Whether something accepts a connection to C<$address> on C<$port>, within
C<$CONNECT_TIMEOUT> seconds.

A false answer is not proof that nothing is there.  A gateway that forwards a
port often does not answer its own public address from inside the network it
forwards into, so this says no for a forward that works perfectly from
outside.  Callers say that rather than reporting a broken forward.

=cut

our $CONNECT_TIMEOUT = 5;

sub answers_on {
    my ( $class, $address, $port ) = @_;

    my $packed = Socket::inet_aton($address)                          or return 0;
    socket( my $socket, Socket::PF_INET(), Socket::SOCK_STREAM(), 0 ) or return 0;

    # Non-blocking, so a filtered port costs the timeout rather than the
    # kernel's own, which is a couple of minutes.
    my $answered = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $CONNECT_TIMEOUT;
        my $ok = connect( $socket, Socket::pack_sockaddr_in( $port, $packed ) );
        alarm 0;
        $ok ? 1 : 0;
    } // 0;

    alarm 0;
    close($socket) or undef;

    return $answered;
}

=head1 THE SANDBOX OF A FETCH

=head2 sandbox_error

Returns undef if bubblewrap can make the sandbox of F<rsyncd_sandbox> here,
and otherwise the reason that it cannot.  The forced command of the key of
every guest runs in that sandbox, so a guest cannot fetch anything while the
reason holds.  See C<write_rsyncd_conf> in F<bin/new_config>.

It runs C<bwrap> with the same namespaces as F<rsyncd_sandbox>, because the
program can be there and still be refused.  Ubuntu 24.04 lets a program make a
user namespace only if AppArmor gives it a profile that allows that.  The
object keeps the answer.

=cut

sub sandbox_error {
    my ($self) = @_;
    return $self->{sandbox_error} if exists $self->{sandbox_error};

    my $bwrap = File::Which::which('bwrap');
    return $self->{sandbox_error} = 'bwrap is not installed' unless $bwrap;

    my $said;
    IPC::Run3::run3( [ $bwrap, qw{--unshare-all --die-with-parent --ro-bind / / true} ], \undef, \$said, \$said );
    return $self->{sandbox_error} = undef if $? == 0;

    chomp $said;
    return $self->{sandbox_error} = "bwrap could not make a sandbox: $said";
}

=head2 sandbox_program

The path of the F<rsyncd_sandbox> that the forced command of every guest key
runs: F<rsyncd_sandbox> in C<$Trog::Utils::LIBEXEC>.

=cut

sub sandbox_program {
    return "$Trog::Utils::LIBEXEC/rsyncd_sandbox";
}

=head2 sandbox_program_error

Returns undef if C<sandbox_program> is a file that root owns, that only root can
write, and that everybody can run.  Otherwise it returns the reason that it is
not.  The account that a guest connects as runs it, and it must not be able to
change what it runs.  F<scripts/setup_transfer_user> installs it.

=cut

sub sandbox_program_error {
    my ($self) = @_;

    my $path = $self->sandbox_program;
    my @st   = stat $path;
    return "$path is not there" unless @st;

    my ( $mode, $uid ) = @st[ 2, 4 ];
    return "$path is not a file" unless S_ISREG($mode);
    return "$path is not owned by root"               if $uid != 0;
    return "$path can be written by others than root" if $mode & oct('022');
    return "$path cannot be run by every account"     if ( $mode & oct('0111') ) != oct('0111');
    return;
}

=head1 THE KEYS OF GUESTS

A guest fetches its payload from this machine over ssh, as the account that
C<transfer_user> names.  sshd lets its key in through
F<scripts/guest_authorized_keys>, which reads one file per guest from
C<$Trog::Utils::GUEST_KEYS> and gives each key no command but the sandbox.  So
the account that runs F<bin/provision> never edits an F<authorized_keys> file,
and it can be another account than the one that the guest connects as.
F<scripts/setup_transfer_user> sets this up.

=head2 authorize_guest_key($name, $dir, $pubkey)

Lets C<$pubkey> fetch from C<$dir>, the domain directory of C<$name> that holds
its F<rsyncd.conf>: it writes C<$dir> and C<$pubkey>, a line each, to the file
C<$name> in the directory of guest keys.  The file is replaced whole, and
everybody can read it, because sshd reads it as C<nobody>.  Returns 1.

Dies if C<$name> is not a domain name, if C<$dir> is not a path that the helper
takes, or if it cannot write the file.

=cut

# What scripts/guest_authorized_keys takes, which a key line can hold
# unquoted.  The pattern in guest_name is for the key line: is_domain takes a
# final dot, and does not promise to stay inside ASCII.
our $GUEST_DIR = qr{\A/[[:alnum:]._/+-]+\z};

my sub guest_name ($name) {
    return $name =~ m/\A[[:alnum:].-]+\z/ && $name !~ m/[.]\z/ && defined Data::Validate::Domain::is_domain( $name, { domain_disable_tld_validation => 1 } );
}

sub authorize_guest_key {
    my ( $self, $name, $dir, $pubkey ) = @_;

    die "'$name' is not a domain name, so it cannot name a guest key\n" unless guest_name($name);
    die "sshd cannot be given '$dir' in a key line: it must be an absolute path of letters, digits and ._/+-\n"
      unless $dir =~ $GUEST_DIR;

    return Trog::Utils::write_binary_mode( "$Trog::Utils::GUEST_KEYS/$name", "$dir\n$pubkey\n", oct('0644') );
}

=head2 $had = revoke_guest_key($name)

Removes the file that C<authorize_guest_key> wrote for C<$name>.  Returns 1 if
there was one, and 0 if not.  Dies if C<$name> is not a domain name, or if it
cannot remove the file.

=cut

sub revoke_guest_key {
    my ( $self, $name ) = @_;

    die "'$name' is not a domain name, so it names no guest key\n" unless guest_name($name);

    my $file = "$Trog::Utils::GUEST_KEYS/$name";
    return 0 unless -e $file;
    unlink $file or die "Could not remove $file: $!\n";
    return 1;
}

=head2 guest_keys_error

Returns undef if this account can write a file into the directory of guest
keys, and otherwise the reason that it cannot.  It finds out by writing one,
and removing it again.

=cut

sub guest_keys_error {
    my ($self) = @_;

    my $dir = $Trog::Utils::GUEST_KEYS;
    return "$dir is not there" unless -d $dir;
    my $probe = eval { File::Temp->new( DIR => $dir ) };
    return "this account cannot write $dir" unless $probe;
    return;
}

=head1 SEE ALSO

L<Trog::Machine>, L<Trog::HV>, L<Trog::Guest>

=cut

1;
