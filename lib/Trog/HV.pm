package Trog::HV;

#ABSTRACT: the hypervisor we are provisioning against, whichever kind it is.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::Machine';

use Trog::Config();
use Trog::Credentials();
use Trog::Secrets();
use Provisioner::Cookbook();
use File::Slurper();
use YAML::XS();

use File::Which();
use Time::Piece();
use List::Util qw{any uniq};

=head1 NAME

Trog::HV - the hypervisor we are provisioning against, whichever kind it is

=head1 SYNOPSIS

    use Trog::HV();

    my $config = Config::Simple->new('/opt/domains/vm.example.test/provision.conf');
    my $uri    = 'qemu+ssh://root@hv1.example.test/system';    # or undef

    # Once, wherever the config and command line are read:
    Trog::HV->from_config($config, uri => $uri);

    # Everywhere else, in any package, without threading it through:
    my $hv = Trog::HV->new();

    $hv->annihilate_domain('vm.example.test');
    print $hv->domain_dir, "\n";

=head1 DESCRIPTION

Everything in this toolkit that works with the hypervisor goes through this
class.  Everything that depends on the kind of hypervisor goes through a backend.

This class is what the rest of the toolkit talks to.  It owns the singleton, the
directory for each domain, and the arithmetic that decides which hypervisor a
guest fits on.  None of these depends on what runs the guests.  A backend owns
the rest.

The object is a singleton.  C<< Trog::HV->new() >> with no arguments returns the
hypervisor that this process configured earlier, so callers do not pass it
around.  The object that comes back is a backend instance.  It answers to every
method here I<and> to every method that the backend adds.

=head1 WHAT A BACKEND HAS TO PROVIDE

A backend is a subclass of this class.  L</backend_for(%opts)> chooses it, and
its own C<build> makes it.  This class and the scripts above it call the methods
below, so a backend must answer to each one:

=over 4

=item * C<build(%opts)> and C<config_keys>: how to make one, and which
F<hypervisors.conf> keys make it.  C<marker>, the one option that says a block
is this kind: see L</backend_for(%opts)>.

=item * C<is_local> and C<describe>, which every diagnostic prints.
L<Trog::Machine> gives a default for both.

=item * C<capacity>, in the form that L</shortfalls(%needs)> and
L</headroom(%needs)> read: a hash with C<memory_mb>, C<memory_free>,
C<memory_committed>, C<cpus>, C<cpus_allocatable>, C<cpus_committed>,
C<cpus_free>, C<disk_free> and C<guests>.

=item * C<monthly_cost>, if a guest costs money there.  See
L</monthly_cost(%needs)>.

=item * C<size_key>, the C<_global> key that says what a guest is on this kind
of hypervisor, such as C<linode_type>, or undef for a hypervisor that sizes a
guest from its C<memory>, C<cpus> and C<size>.  See L</PLACEMENT>.

=item * The guest lifecycle, C<domain_exists> and C<annihilate_domain>.  Also
the four snapshot methods: C<snapshot_names>, C<snapshot_current_name>,
C<create_snapshot> and C<revert_snapshot>.

=item * C<guest_names>, every guest that the backend has.  An orphan sweep uses
it to tell that a directory belongs to a guest that still exists.

=item * C<guest_ssh_ip>, the address at which you reach a built guest.

=item * C<image_for_distro($distro)>, what this hypervisor boots a guest of that
distribution from: a URL, a Glance image, a Linode image.  The distro recipe
decides the distribution and the release, and every kind of hypervisor answers
for the same pair.  F<bin/new_config> writes the answer into F<provision.conf>
as C<image>.  Dies when this hypervisor has no image for it.

=item * C<inspection_address($domain)>, the address at which a person reaches a
built guest to look at it, for the scripts that collect its logs or ask it
something.  It works when the build did not, which is when it is wanted.

=item * C<clear_guest>, which removes what must go before a guest of that name
can be made.  For libvirt, that is the domain, its disks and the addresses it
held.  A cloud rebuilds the server it already has, so it has nothing to clear.
It takes C<keep_disk>, which tells it to leave the disk of the guest in place.
See C<rollback_possible> for when that is allowed.

=item * C<rollback_possible($domain, capacity =E<gt> $bytes)>, whether a
snapshot taken now is still there to go back to after the rebuild.
C<snapshot_before_rebuild> asks it.

The two backends answer it for opposite reasons.  A cloud snapshot is an image
outside the server.  It survives whatever happens to the guest, so the answer is
yes when a server exists.  A libvirt snapshot lives inside the qcow2 file of the
guest, so it survives only if that file does.  The file survives only when the
disk is kept, and the disk is kept only when the requested disk did not change.

=item * C<provision_guest>, the guest itself, made from the seed that
C<bin/provision> wrote.  It returns the address that the guest came up at.
C<guest_ssh_ip> then tells how to reach that guest.

=item * C<would_provision>, for a dry run.  It describes what C<clear_guest>
and C<provision_guest> are to do, and does not do it.

=item * C<prepare_host>, C<release_seed> and C<guest_volumes>: the work on a
hypervisor before it can build, on a guest after cloud-init reads its seed, and
on the disks of a guest after it is gone.  A backend with nothing to do for one
of them does nothing.  So the scripts above call all three, and do not ask first
which kind of hypervisor they have.

=item * C<builds_by_api> and C<manages_addresses>.  L<Provisioner::Recipe::ubuntu>,
F<bin/new_config> and L<Provisioner::IPPool> branch on these, not on a class
name.  They are only for where the two kinds take different paths: a guest
defined from XML or requested from a service, an address that we allocate or one
that we receive.  They are not for a step that one kind does not need.  The
three methods above are for that.  Both are false here.

=item * C<preflight_checks> and C<preflight_notes>, and the checks
C<check_reachable> and C<check_transfer_ip>.  See L</PREFLIGHT>.

=back

This class declares each method in the list that it does not answer itself.
That declaration dies, and names the backend and the missing method.  So a new
backend that leaves one out gets a clear error at the call, not "Can't locate
object method" from somewhere in F<bin/provision>.

If a method means nothing to a backend, the backend must die and say so.  It
must not return an undef that the caller carries somewhere else before it fails.

=for Pod::Coverage config_keys marker annihilate_domain revert_snapshot inspection_address image_for_distro

=head1 CLASS METHODS

=cut

# The one hypervisor this process is talking to.
my $INSTANCE;

=head2 new(%opts)

Build or return the hypervisor.

If no option is set, it returns the instance built earlier in the process.  If
there is none, it builds a local one.  If options are set, it builds a new
hypervisor and makes I<that> the instance from then on.  So the configuration
is read only once.

The options are the constructor options of each backend (see C<config_keys>),
the limits under L</PLACEMENT>, and C<name>.  An option with a false value
(undef, empty or 0) is dropped.  So callers can pass unset command line options
straight through.

=cut

sub new {
    my ( $class, %opts ) = @_;

    # An option that is not set is not a request for a different hypervisor,
    # so a call that passes none gets the current one.
    return $INSTANCE if $INSTANCE && !any { $opts{$_} } keys %opts;

    return $class->candidate(%opts)->activate();
}

=head2 activate

Make this hypervisor the one that C<new> returns from now on.  Returns the
object, so calls can chain.

=cut

sub activate {
    my ($self) = @_;
    $INSTANCE = $self;
    return $self;
}

=head2 candidate(%opts)

Build a hypervisor and return it, but do not make it the current one.

C<new> is a singleton because almost every caller wants the one hypervisor of
this run.  L<Trog::Hypervisors> is the exception.  It holds several hypervisors
at once to compare them, and only the winner becomes current.  Takes the same
options as C<new>.  Dies where C<backend_for> or the C<build> of the backend
dies.

=cut

sub candidate {
    my ( $class, %opts ) = @_;

    my %given = map { $_ => $opts{$_} } grep { $opts{$_} } keys %opts;

    # Called on a backend class, use that backend.  Called on this class, choose one.
    my $backend = $class eq __PACKAGE__ ? $class->backend_for(%given) : $class;

    return $backend->build(%given);
}

=head2 backends

Returns the class name of every backend, and loads each one.

=cut

sub backends {
    my ($class) = @_;

    my @backends = map { __PACKAGE__ . "::$_" } qw{Libvirt OpenStack Linode};

    # Loaded with require here, not with use at the top: each backend is a
    # subclass of this class, so a load at compile time makes a cycle.
    foreach my $backend (@backends) {
        my $path = $backend =~ s{::}{/}gr;
        require "$path.pm";    ## no critic (Modules::RequireBarewordIncludes)
    }

    return @backends;
}

=head2 backend_for(%opts)

Returns the backend class that these options ask for: the one whose C<marker>
option is set, or L<Trog::HV::Libvirt> when none is.  Dies if more than one is.

This is the one seam.  Everything else about another kind of hypervisor is a
subclass, and this method decides which subclass you get.

=cut

sub backend_for {
    my ( $class, %opts ) = @_;

    # A cloud has a name, a libvirt hypervisor has a URI, and a Linode account
    # has a token.  A configuration that names two cannot be satisfied, so do
    # not choose one of them.
    my @backends = $class->backends;
    my @named    = grep { $opts{ $_->marker } } @backends;

    die 'A hypervisor is one of ' . join( ', ', map { $_->marker_key } @backends ) . ', and this has ' . join( ' and ', map { $_->marker_key } @named ) . ".\n"
      if @named > 1;

    return $named[0] // __PACKAGE__ . '::Libvirt';
}

=head2 marker_key

The F<hypervisors.conf> key of a backend's C<marker>, which is how a person
writing the file knows it.

=cut

sub marker_key {
    my ($class) = @_;

    my %in_file = $class->config_keys;
    return $in_file{ $class->marker };
}

=head2 options_from_block($block)

Turn one F<hypervisors.conf> block into constructor options, and return them as
a list of pairs.  A key that the block does not set is left out.

It reads the keys of every backend, because the content of a block decides
which backend it describes.  So all keys must be read before that decision.
Each backend names its own keys in C<config_keys>.  This class reads the
placement limits, because placement belongs to this class, and C<transfer_ip>
and C<transfer_port>, because every kind of hypervisor has guests that fetch
from us.

=cut

my @LIMIT_KEYS = qw{reserve_memory reserve_cpus reserve_disk max_guests cpu_overcommit};

# Where a guest of this hypervisor reaches us, which is any backend's question.
my @TRANSFER_KEYS = qw{transfer_ip transfer_port};

sub options_from_block {
    my ( $class, $block ) = @_;

    my %opts;
    foreach my $backend ( $class->backends ) {
        my %keys = $backend->config_keys;
        foreach my $option ( sort keys %keys ) {
            my $in_file = $keys{$option};
            $opts{$option} = $block->{$in_file} if defined $block->{$in_file};
        }
    }

    $opts{$_} = $block->{$_} for grep { defined $block->{$_} } @LIMIT_KEYS, @TRANSFER_KEYS;

    return %opts;
}

=head2 from_config($config, %override)

Build the hypervisor from a L<Config::Simple> object through C<new>, and return
it.  A value in C<%override>, for example from the command line, wins over the
file.  An empty override counts as not given, as it does in C<new>, so the file
still answers for it.  A false C<$config> is allowed, and means that every value
takes its default.

It reads every key that a backend names in C<config_keys>: C<libvirt_uri> for
C<uri>, and the rest under their own names.

=cut

sub from_config {
    my ( $class, $config, %override ) = @_;

    # The keys of every backend, because what a configuration contains decides
    # which backend it describes.
    my %key = map { $_->config_keys } $class->backends;

    return $class->new( map { $_ => ( $override{$_} || $class->config_value( $config, $key{$_} ) ) } keys %key );
}

=head2 config_value($config, $key)

Returns one value from a configuration, which is a L<Config::Simple> object or
a plain hashref.  A key that is given more than once returns its first value.
Returns undef when there is no configuration, no such key, or an empty value.

=cut

sub config_value {
    my ( $class, $config, $key ) = @_;
    return undef unless $config;

    my $value = ref $config eq 'HASH' ? $config->{$key} : $config->param($key);
    $value = $value->[0] if ref $value eq 'ARRAY';
    return ( length $value ) ? $value : undef;    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a setting of "0" is still a setting
}

=head2 forget()

Drop the stored instance.  Only the tests call this.

=cut

sub forget {
    undef $INSTANCE;
    return 1;
}

=head2 setting($name)

One value from the block of this hypervisor in F<hypervisors.conf>, with a
C<secret:> reference resolved.

Any value in a block may be a reference, as a value in F<recipes.yaml> may:
C<secret:GROUP/ENTRY/FIELD>, resolved against the secret store.  A Linode
token is one, and so is anything else a backend would otherwise read in the
clear from a file that lives in a repository.

The store is opened at the first value that needs it, and not before, so a run
that touches no hypervisor whose block holds one is never asked for the
passphrase.  The answer is kept for the rest of the run.  Every backend reads
its configuration through this, so none of them resolves a reference itself.

=cut

sub setting {
    my ( $self, $name ) = @_;

    my $value = $self->{$name};
    return $value                   if ref $value || !defined $value || index( $value, 'secret:' ) != 0;
    return $self->{_secrets}{$name} if exists $self->{_secrets}{$name};

    my %found = Trog::Secrets->lookup(
        Trog::Config->path('secrets.kdbx'),
        Trog::Credentials->prompt( 'Enter password:', 'keepass' ),
        $name => $value,
    );

    return $self->{_secrets}{$name} = $found{$name};
}

=head1 IDENTITY

=head2 name

Returns the name of this hypervisor in F<hypervisors.conf>, or undef if it did
not come from there.

=cut

sub name ($self) { return $self->{name} }

=head2 explicit

Whether somebody asked for this hypervisor, as opposed to a default choice.
Callers read it as "somebody already decided, do not place around them".  Any
backend can answer that, so it lives here.  At present, only a connection URI
can take a default.

=cut

sub explicit ($self) { return $self->{explicit} }

=head2 configured_transfer_ip, configured_transfer_port

The address and the ssh port of this machine that a guest of this hypervisor
fetches its payload from, when its block in F<hypervisors.conf> names them, or
undef.  They win over the C<_global> of F<recipes.yaml>, because the answer
depends on where the guest is.  A guest on a machine of ours reaches us across
our own network.  A guest on a cloud reaches us through the gateway, at an
address and a port forwarded past it.

Dies when C<transfer_port> is not a port number.

=cut

sub configured_transfer_ip ($self) { return $self->setting('transfer_ip') }

sub configured_transfer_port ($self) {
    my $port = $self->setting('transfer_port');
    return $port if !defined $port || $port =~ m/\A\d{1,5}\z/ && $port > 0 && $port < 65536;
    die "transfer_port for " . ( $self->name // $self->describe ) . " is '$port', which is not a port\n";
}

=head1 PATHS

=head2 domain_dir

Returns the directory that holds the directory of each domain.  It is not the
business of a backend.  It is a directory on the machine that runs this code,
and it holds what we generated for a guest.  Its meaning does not change with
how the guest gets built.

=cut

sub domain_dir ($self) { return $self->{domain_dir} // $self->default_domain_dir }

=head2 default_domain_dir

Returns the directory for domains when nothing else sets one.

It is a class method, so C<bin/provision> and C<bin/restore> can call it before
they have a hypervisor.  C<bin/provision> needs the path to find
F<provision.conf>, and F<provision.conf> names the hypervisor.  Keep the default
here only, so that the two cannot disagree.

=cut

sub default_domain_dir { return '/opt/domains' }

=head1 WHICH WAY A GUEST GETS BUILT

The code above this class asks two questions.  Each backend answers them in its
own way, and no caller answers them from a class name.

=head2 builds_by_api

Whether a service creates a guest on request, as opposed to a domain defined
from the XML that L<Provisioner::Recipe::vm> renders.  If it does, the service
assigns the MAC and the image names the interfaces.  So
L<Provisioner::Recipe::ubuntu> leaves the network configuration to the image.

It is I<not> for the storage pool, the seed ISO or the cdrom.  Those are
L</prepare_host($virtiofs)>, L</release_seed($domain)> and
L</guest_volumes($domain)>, and a guest that a service builds answers them by
doing nothing.

=head2 manages_addresses

Whether the hypervisor gives its guests their addresses, so that we do not
choose one out of the address pool.

If it does, the pool has nothing to allocate and nothing of ours to collide
with.  L<Provisioner::IPPool> does not sweep that hypervisor, because its
addresses do not come from the pool.

=cut

sub builds_by_api     { return 0 }
sub manages_addresses { return 0 }

=head2 @actions = $hv->debug_actions()

The actions of F<bin/debug_boot> that this backend can do, named as the options
are: C<console>, C<fetch>, C<hold>, C<shot>, C<vnc>, C<keys>, C<restore>,
C<cat>, C<ls>, C<single>.

Empty by default, so a backend that says nothing debugs nothing and the tool
refuses before it touches the guest.  A backend that names an action
implements the methods below that the action uses.

=cut

sub debug_actions { return () }

=head2 $restarted = $hv->console_capture($domain, wait =E<gt> $seconds)

Makes the console of C<$domain> readable by C<console_output>, and
returns whether it restarted the guest to do it.

A backend that has to redirect the console restarts the guest, waits
C<$seconds> for it to boot, and returns true.  A backend that keeps the console
of every guest does nothing and returns false.

=head2 $text = $hv->console_output($domain)

What the console of C<$domain> has printed, as text, or undef if there is none
to read.

=head2 ($advice, $value) = $hv->vnc_access($domain)

How to reach the display of C<$domain>.  C<$advice> is text for the operator,
which names what stands between them and the display, such as an ssh tunnel.
C<$value> is the one thing a caller can act on: a port, or a URL.

Dies if the guest has no display.

=cut

=head1 WHAT EVERY BACKEND ANSWERS

This class declares these methods, so a backend that leaves one out gets an
error that names the method.  See L</WHAT A BACKEND HAS TO PROVIDE> for the
purpose of each.

=head2 prepare_host($virtiofs)

Does what the hypervisor needs before a guest can be built on it.  C<$virtiofs>
is our copy of F<virtiofs-better>, for a backend whose guests run in a qemu
process that uses it.

=head2 release_seed($domain)

Called after the guest reports that cloud-init finished, and not before.  Until
then, the guest can still be reading its seed.

=head2 guest_volumes($domain)

Returns the volumes that belong to this guest alone, which we delete after the
guest is gone.  Never the base image, because every other guest is built on it.

=cut

# Declared, so the error names the class and the method that it owes.
sub _abstract {
    my ( $self, $method ) = @_;
    die( ( ref($self) || $self ) . " does not implement $method, which every backend has to\n" );
}

sub build                 ( $self, @ ) { return $self->_abstract('build') }
sub config_keys           ( $self, @ ) { return $self->_abstract('config_keys') }
sub marker                ( $self, @ ) { return $self->_abstract('marker') }
sub domain_exists         ( $self, @ ) { return $self->_abstract('domain_exists') }
sub annihilate_domain     ( $self, @ ) { return $self->_abstract('annihilate_domain') }
sub guest_names           ( $self, @ ) { return $self->_abstract('guest_names') }
sub guest_ssh_ip          ( $self, @ ) { return $self->_abstract('guest_ssh_ip') }
sub inspection_address    ( $self, @ ) { return $self->_abstract('inspection_address') }
sub image_for_distro      ( $self, @ ) { return $self->_abstract('image_for_distro') }
sub snapshot_names        ( $self, @ ) { return $self->_abstract('snapshot_names') }
sub snapshot_current_name ( $self, @ ) { return $self->_abstract('snapshot_current_name') }
sub create_snapshot       ( $self, @ ) { return $self->_abstract('create_snapshot') }
sub revert_snapshot       ( $self, @ ) { return $self->_abstract('revert_snapshot') }
sub prepare_host          ( $self, @ ) { return $self->_abstract('prepare_host') }
sub release_seed          ( $self, @ ) { return $self->_abstract('release_seed') }
sub guest_volumes         ( $self, @ ) { return $self->_abstract('guest_volumes') }
sub clear_guest           ( $self, @ ) { return $self->_abstract('clear_guest') }
sub rollback_possible     ( $self, @ ) { return $self->_abstract('rollback_possible') }
sub provision_guest       ( $self, @ ) { return $self->_abstract('provision_guest') }
sub would_provision       ( $self, @ ) { return $self->_abstract('would_provision') }
sub console_capture       ( $self, @ ) { return $self->_abstract('console_capture') }
sub console_output        ( $self, @ ) { return $self->_abstract('console_output') }
sub vnc_access            ( $self, @ ) { return $self->_abstract('vnc_access') }

=head2 $name = $hv->snapshot_before_rebuild($domain, capacity =E<gt> $bytes)

Takes a snapshot just before a rebuild, as the rollback point, and returns its
name.  C<capacity> is the size that the rebuild asks for, and
C<rollback_possible> uses it.  Backends do not override this method.

Returns undef whenever the snapshot did not happen.  That is when
C<rollback_possible> is false, or when C<create_snapshot> warns and returns
false.  The caller offers a returned name to an operator as the way back.  So a
name for a snapshot that does not exist is worse than no name.

The name holds the date and the time to the second.  An operator reads it back
out of the backend and types it at C<bin/restore>.  It has no colons, because
it goes onto a command line, and on libvirt into the snapshot XML too.  Nothing
sorts on it, because C<snapshot_names> sorts by creation time.

=cut

sub snapshot_before_rebuild {
    my ( $self, $domain, %opts ) = @_;

    return unless $self->rollback_possible( $domain, capacity => $opts{capacity} );

    my $name = 'before-reprovision-' . Time::Piece::localtime()->strftime('%Y-%m-%d-%H%M%S');

    # Disk only, and left down: the rebuild follows at once, so a memory image
    # and a restart are waste.  A cloud ignores both options.
    return $self->create_snapshot( $domain, $name, disk_only => 1, leave_down => 1 ) ? $name : undef;
}

=head2 $hv->rebuild_destroys_guest($domain, capacity =E<gt> $bytes)

Whether a rebuild of this domain takes the existing guest apart, as opposed to
a build over it.  C<capacity> is the size that the build asks for.

False here: a backend that replaces the root disk of a server in place keeps the
server and its addresses, so nothing is lost.  L<Trog::HV::Libvirt> overrides
it.  F<bin/provision> decides what to do about a true answer.

=cut

sub rebuild_destroys_guest { return 0 }

=head2 $hv->clone_guest_disk($domain)

Copies the disk of a guest aside before a rebuild destroys it.  Returns where
the copy is, or undef.  Undef here, and nothing calls this one: only a backend
that answers true to C<rebuild_destroys_guest> has a guest to copy aside.

=cut

sub clone_guest_disk { return }

=head2 $hv->backup_volumes

Returns the names of the disks that C<clone_guest_disk> left behind.  An empty
list here, for the same reason.  Callers ask for this list and do not match
names themselves, so the name of a copy stays the business of the backend.

=cut

sub backup_volumes { return () }

=head1 PLACEMENT

Whether one more guest fits, and which hypervisor it fits on best.

The numbers come from the C<capacity> of a backend.  The judgment is here, so
the same rules place guests on every backend.

=head2 reserve_memory, reserve_cpus, reserve_disk, max_guests, cpu_overcommit

The limits from F<hypervisors.conf>.  C<reserve_memory> is the MB to keep for
the host, and C<reserve_cpus> is the CPUs to keep for the host.  C<reserve_disk>
is the bytes to keep free in the pool.  C<max_guests> caps the domain count, and
0 means no cap.  C<cpu_overcommit> is the acceptable number of vCPUs for each
physical CPU.  The defaults are 2048MB, 1 CPU, 10GB, no cap, and 4.

=cut

sub reserve_memory ($self) { return $self->{reserve_memory} // 2048 }
sub reserve_cpus   ($self) { return $self->{reserve_cpus}   // 1 }
sub reserve_disk   ($self) { return $self->{reserve_disk}   // 10 * 1024 * 1024 * 1024 }
sub max_guests     ($self) { return $self->{max_guests}     // 0 }
sub cpu_overcommit ($self) { return $self->{cpu_overcommit} // 4 }

=head2 capacity(%needs)

Returns what the hypervisor has, and what it already promised.  The backend
provides it.  L</WHAT A BACKEND HAS TO PROVIDE> lists the keys of the hash.

C<%needs> is what the guest asks for, as L</shortfalls(%needs)> takes it.  A
machine has what it has whatever the guest wants, and ignores it.  A hypervisor
that sells a guest a size answers for the size this guest names in its
C<size_key>.

=cut

sub capacity ( $self, @ ) { return $self->_abstract('capacity') }

=head2 size_key

The C<_global> key that says what a guest is on this kind of hypervisor.  Undef
here, which is what a hypervisor that sizes a guest from its C<memory>, C<cpus>
and C<size> answers.  A hypervisor that sells sizes by name returns its key,
and a guest whose C<_global> does not name one is not built there: see
L</shortfalls(%needs)>.

=cut

sub size_key { return undef }

=head2 monthly_cost(%needs)

Returns what a guest that wants C<memory_mb>, C<cpus> and C<disk_bytes> would
cost a month here, as a number in the currency the backend bills in.
L<Trog::Hypervisors/place($domain, %needs)> chooses the cheapest hypervisor that
fits before the roomiest one.

0 here: a machine that we own costs the same whether it runs one more guest or
not.  A backend that bills for each guest overrides it.  It dies when it cannot
find the price, and placement then reports it as unreachable, because a guess at
a price is the one answer that spends money.

=cut

sub monthly_cost { return 0 }

=head2 shortfalls(%needs)

Returns every reason why this hypervisor cannot take a guest that wants
C<memory_mb>, C<cpus> and C<disk_bytes>.  Each reason is text that a person can
act on.  An empty list means that the guest fits.

=cut

sub shortfalls {
    my ( $self, %needs ) = @_;

    my $have = $self->capacity(%needs);
    my @reasons;

    push @reasons, sprintf(
        'needs %dMB of memory, %dMB free (%dMB physical, %dMB committed, %dMB reserved)',
        $needs{memory_mb},  $have->{memory_free},
        $have->{memory_mb}, $have->{memory_committed}, $self->reserve_memory
    ) if ( $needs{memory_mb} // 0 ) > $have->{memory_free};

    push @reasons, sprintf(
        'needs %d vCPUs, %d free (%d CPUs x%d overcommit, %d committed, %d reserved)',
        $needs{cpus},  $have->{cpus_free},
        $have->{cpus}, $self->cpu_overcommit, $have->{cpus_committed}, $self->reserve_cpus
    ) if ( $needs{cpus} // 0 ) > $have->{cpus_free};

    push @reasons, sprintf(
        'needs %dGB of disk, %dGB free in the pool after a %dGB reserve',
        _gb( $needs{disk_bytes} ), _gb( $have->{disk_free} ), _gb( $self->reserve_disk )
    ) if ( $needs{disk_bytes} // 0 ) > $have->{disk_free};

    push @reasons, sprintf( 'already has %d guests, and max_guests is %d', $have->{guests}, $self->max_guests )
      if $self->max_guests && $have->{guests} >= $self->max_guests;

    return @reasons;
}

sub _gb ($bytes) { return int( ( $bytes // 0 ) / ( 1024 * 1024 * 1024 ) ) }

=head2 headroom(%needs)

Returns how much room this hypervisor has left after it takes the guest, from 0
(exactly full) to 1 (empty).  The value comes from the tightest of the three
resources.  Placement by the tightest resource stops one hypervisor from filling
its disk while the fleet still has plenty of RAM.

=cut

sub headroom {
    my ( $self, %needs ) = @_;

    my $have = $self->capacity(%needs);
    my @fractions;

    push @fractions, _fraction( $have->{memory_free} - ( $needs{memory_mb} // 0 ), $have->{memory_mb} );
    push @fractions, _fraction( $have->{cpus_free} - ( $needs{cpus}        // 0 ), $have->{cpus_allocatable} );
    push @fractions, _fraction( $have->{disk_free} - ( $needs{disk_bytes} // 0 ), $have->{disk_free} + ( $needs{disk_bytes} // 0 ) );

    my ($tightest) = sort { $a <=> $b } @fractions;
    return $tightest;
}

sub _fraction {
    my ( $left, $total ) = @_;
    return 0 if !$total;
    my $fraction = $left / $total;
    return $fraction < 0 ? 0 : $fraction;
}

=head1 PREFLIGHT

What a hypervisor can report about itself before a guest is built on it.

C<bin/preflight> prints these answers, but does not know them.  The backend
decides which questions matter.  Passwordless sudo means nothing to a cloud, and
a Keystone catalog means nothing to libvirt.  So each backend names the
questions it answers and their order, and the script walks that list.

Every check and note returns C<{ ok =E<gt> 1 }>, or C<{ ok =E<gt> 0, what
=E<gt> ..., fix =E<gt> ... }>.  C<what> says what is wrong, and C<fix> says
what to do about it.

=head2 @names = $hv->preflight_checks()

Returns the names of the checks that this backend answers, in the order to ask
them.  Each name is a method on the backend.  A failed check means that a guest
cannot be built.

=head2 @names = $hv->preflight_notes()

The same, for things that are good to have but not required.

=cut

sub preflight_checks ( $self, @ ) { return $self->_abstract('preflight_checks') }
sub preflight_notes  ( $self, @ ) { return $self->_abstract('preflight_notes') }

=head2 $result = $hv->_verdict($ok, $what, $fix)

Returns the answer of one check, in the form that C<bin/preflight> prints.

=cut

sub _verdict {
    my ( $self, $ok, $what, $fix ) = @_;
    return { ok => $ok, what => $what, fix => $fix };
}

=head2 $hv->check_reachable(), $hv->check_transfer_ip()

This class declares both, and the backend answers them.  Both questions apply to
either kind, but the answers have nothing in common.

To reach a machine is an ssh login.  To reach a cloud is a credential that
authenticates, and a catalog with compute, image and network in it.  To find the
address that a guest fetches from, libvirt asks the routing table about a NAT
bridge.  A cloud reads it out of the configuration, because it has nothing to
ask until the guest exists.

=cut

sub check_reachable   ( $self, @ ) { return $self->_abstract('check_reachable') }
sub check_transfer_ip ( $self, @ ) { return $self->_abstract('check_transfer_ip') }

=head2 $result = $hv->check_rsync()

Checks that rsync is on this machine and, for a remote hypervisor, on the
hypervisor too.  The data directory of a domain goes up to the hypervisor over
rsync, and comes off the guest that is replaced over rsync.  Nothing else in
this toolkit must exist on both the machine that drives a run and the machine
that it drives.

It does not check guests.  Every guest that this tool builds installs rsync
among its base packages, and a guest that is not built yet has nothing to
salvage.

=cut

sub check_rsync {
    my ($self) = @_;

    my @missing;
    push( @missing, 'this machine' ) unless File::Which::which('rsync');
    push( @missing, $self->describe ) if !$self->is_local && $self->run_cmd( 'sh', '-c', 'command -v rsync >/dev/null 2>&1' ) != 0;

    return $self->_verdict( 1, 'rsync on both ends', q{} ) unless @missing;

    my $where = join( ' and ', @missing );
    return $self->_verdict( 0, "No rsync on $where", <<"FIX" );
A domain's data directory is shipped to the hypervisor and salvaged off the old
guest with it, and both of those compare before they transfer -- which is what
keeps a re-provision from moving twenty gigabytes of video it already has.

    sudo apt install rsync

on $where.
FIX
}

=head2 $result = $hv->check_fetch_sources()

Checks that every directory that a recipe fetches from this machine exists here.

A recipe that ships the files of an operator names a directory that nothing here
creates, for example C<skel> for adminconfig or C<cert_dir> for openvpnclient.
The guest copies those out of this machine with rsync.  If one is absent, the
target of that recipe fails partway through a build.  The rsync error names
neither the recipe nor the domain.

It checks every domain, because preflight is about the machine and C<skel> is
usually set once in C<_base> for the whole fleet.  It reads the configuration
raw, without validation or enrichment.  A configuration that still has a
CHANGEME in it is one that somebody is writing, and they need this answer next.

=cut

sub check_fetch_sources {
    my ($self) = @_;

    my $conf = eval { Provisioner::Cookbook->configuration() } // {};
    my %wanted;

    foreach my $domain ( grep { !m/\A_/ } sort keys %$conf ) {
        my $recipes = eval { Provisioner::Cookbook->domain_config( $domain, $conf ) } // {};

        foreach my $name ( sort keys %$recipes ) {
            my $class = eval { Provisioner::Cookbook->load($name) } or next;
            next unless $class->can('fetch_sources');

            my $opts = $recipes->{$name} // {};
            next unless ref $opts eq 'HASH';

            foreach my $path ( eval { $class->fetch_sources(%$opts) } ) {
                next unless $path;
                $wanted{$path}{$name} = 1;
            }
        }
    }

    return $self->_verdict( 1, 'No recipe fetches a directory of yours', q{} ) unless %wanted;

    my @missing = grep { !-d } sort keys %wanted;
    return $self->_verdict( 1, scalar( keys %wanted ) . ' fetched ' . ( keys %wanted == 1 ? 'directory is' : 'directories are' ) . ' here', q{} ) unless @missing;

    my $detail = join( q{}, map { "    $_ (" . join( ', ', sort keys %{ $wanted{$_} } ) . ")\n" } @missing );
    return $self->_verdict( 0, scalar(@missing) . ' fetched ' . ( @missing == 1 ? 'directory is' : 'directories are' ) . ' not on this machine', <<"FIX" );
A guest rsyncs these out of this machine, and the recipe that wants one fails
when it is not there:

$detail
An older installation keeps them on the hypervisor.  If yours does, bring them
here:

    rsync -a @{[ $self->ssh_host // 'the-hypervisor' ]}:<path>/ <path>/
FIX
}

=head2 $result = $hv->check_config()

Checks that the configuration directory from L<Trog::Config> has a readable
F<recipes.yaml>, an F<admin_authorized_keys> that is not empty, and a
F<recipes.yaml> that says what its guests are built with.  See
L<Provisioner::Cookbook/global_schema>.

=cut

sub check_config {
    my ($self) = @_;

    my $dir = Trog::Config->dir;

    my @missing = grep { !_readable("$dir/$_") } qw{recipes.yaml admin_authorized_keys};

    # An empty key file passes a check for existence and then stops
    # bin/new_config, which is the failure that this check prevents.
    push( @missing, 'admin_authorized_keys' )
      if !@missing && !-s "$dir/admin_authorized_keys";

    if ( !@missing ) {
        my $said = eval { Provisioner::Cookbook->globals(undef) };
        return $self->_verdict( 1, "Configuration to copy from: $dir", q{} ) if $said;

        # Ten minutes into a build otherwise: bin/new_config reads these for
        # the first domain it generates, and every recipe that owns a file on
        # the guest wants one of them.
        return $self->_verdict( 0, 'The settings every guest is built with are not there', "$@" . <<"FIX" );
An installation that still has an ipmap.cfg in $dir has them
in that file, and moves them across with:

    bin/ipmap_to_globals --dryrun
    bin/ipmap_to_globals

docs/CONFIGURATION.md says what each one is.
FIX
    }

    return $self->_verdict( 0, "Missing or empty in $dir: " . join( ', ', @missing ), <<"FIX" );
These are where an installation says which machines exist, what every guest
gets, and who may log in to one.  See Trog::Config for where this directory is
and how to point it somewhere else.

admin_authorized_keys is the administrator's public keys, one per line, written
into every guest cloud-init builds.  Seed it from an online identity with:

    ssh-import-id -o $dir/admin_authorized_keys gh:YOURNAME

lp: for Launchpad.  Holding them here rather than naming an identity for the
guest to resolve is deliberate: cloud-init would fetch them from GitHub while
the guest boots, which delays every provision and fails when GitHub is down.
FIX
}

=head2 @distros = $hv->distros_in_use()

The distro recipes that the configuration builds guests of, loaded: the
C<distro> of each domain's C<_global>, C<ubuntu> where it names none, and
C<ubuntu> alone for a configuration with no domains yet.  A preflight check that
asks whether a hypervisor has an image asks it for each of these.

=cut

sub distros_in_use {
    my $conf  = eval { Provisioner::Cookbook->configuration() } // {};
    my %named = map {
        ( ( eval { Provisioner::Cookbook->global_config( $_, $conf ) } // {} )->{distro} // 'ubuntu' ) => 1
    } grep { !m/\A_/ } keys %$conf;
    %named = ( ubuntu => 1 ) unless %named;

    return map { Provisioner::Cookbook->load($_) } sort keys %named;
}

=head2 @values = $hv->globals_in_use($key)

Every value that C<$key> takes in the C<_global> of a domain, sorted, without
repeats.  A preflight check that asks whether a hypervisor can build what the
guests ask for asks it for C<size_key>: the types the configuration names, and
nothing about a type nobody uses.

=cut

sub globals_in_use {
    my ( $class, $key ) = @_;

    my $conf = eval { Provisioner::Cookbook->configuration() } // {};
    my %named;
    foreach my $domain ( grep { !m/\A_/ } keys %$conf ) {
        my $value = ( eval { Provisioner::Cookbook->global_config( $domain, $conf ) } // {} )->{$key};
        $named{$value} = 1 if defined $value && length $value;    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- what somebody wrote, whatever it is
    }

    my @named = sort keys %named;
    return @named;
}

=head2 $result = $hv->note_stale_image()

Whether the image that guests are built on is still the current one from the
distribution.  It is a note and not a check.  A pin one release behind can be a
deliberate decision, and a mirror that does not answer is no reason to refuse a
build.

=cut

sub note_stale_image {
    my @stale;

    foreach my $name ( Provisioner::Cookbook->distros() ) {
        my $distro = Provisioner::Cookbook->load($name);

        # Undef means that the distribution cannot be asked, or did not answer.
        # Either way, there is nothing to report.
        my $current = $distro->current_image or next;
        next if $current eq $distro->base_image;

        push( @stale, { name => $name, have => $distro->base_image, want => $current } );
    }

    return { ok => 1 } unless @stale;

    my $fix = join(
        q{},
        map {
            "$_->{name} builds on
  $_->{have}
and the current release is
  $_->{want}
"
        } @stale
    );

    return {
        ok   => 0,
        what => 'A distro recipe is pinned to an image that is no longer current',
        fix  => $fix . <<'FIX' };
Guests already built are unaffected; this is about the next one.  Change the
release in the distro recipe when you want to move, and rebuild -- see
perldoc Provisioner::DistroRecipe.
FIX
}

=head2 $result = $hv->note_apt_mirror()

Whether anything tells guests where to get their packages.  It reports two
different conditions.  A mirror that is built but that nothing points at is the
worse one, because the work is done and every build still pays for downloads.

It reads the configuration and nothing else.  It does not ask the IP pool
whether a named mirror has an address.  That makes a read-only command create
F<ips.db>, and the question belongs to C<bin/new_config>.

=cut

sub note_apt_mirror {
    my $conf = eval { Provisioner::Cookbook->configuration() } // {};

    my @domains = grep { !m/\A_/ } sort keys %$conf;
    return { ok => 1 } unless @domains;

    my %distro = map { $_ => 1 } Provisioner::Cookbook->distros();
    my ( $pointed, @mirrors );

    foreach my $domain ( @domains, undef ) {
        my $global  = eval { Provisioner::Cookbook->global_config( $domain, $conf ) } // {};
        my $recipes = eval { Provisioner::Cookbook->domain_config( $domain, $conf ) } // {};

        $pointed = 1 if $global->{mirror};

        foreach my $name ( sort keys %$recipes ) {
            my $opts = $recipes->{$name};
            $pointed = 1 if $distro{$name} && ref $opts eq 'HASH' && $opts->{mirror};
            push( @mirrors, $domain ) if $name eq 'aptmirror' && defined $domain;
        }
    }

    return { ok => 1 } if $pointed;

    if (@mirrors) {
        my $built = join( ', ', uniq sort @mirrors );
        return { ok => 0, what => "$built mirrors the archive, and nothing points at it", fix => <<"FIX" };
Every guest still fetches every package over the internet on every build, this
one included.  Name it in the _global that the fleet shares:

    _base:
        _global:
            mirror: $built

A bare name is resolved out of the ip pool, because a guest runs cloud-init
before it has DNS.  A mirror somewhere else is named as a URL instead.
FIX
    }

    my ($parent) = map { m/\A[^.]+[.](\N+)\z/ ? $1 : () } @domains;
    my $suggested = 'aptmirror.' . ( $parent // 'example.com' );

    return { ok => 0, what => 'No package mirror is configured', fix => <<"FIX" };
Every guest downloads its packages over the internet on every provision, and
again on every autoupdate.  Across a fleet that is the same few hundred
megabytes per guest per build.

A mirror is a guest like any other:

    bin/new_guest --hostname $suggested aptmirror

and then, once it has synced, point the fleet at it with `mirror:` in _base's
_global.  Nothing depends on that recipe, and a fleet without one builds exactly
as it does now -- only slower.
FIX
}

=head2 $result = $hv->note_plaintext_secrets()

Whether the configuration holds any secret in clear text.

The secret store exists so that the configuration holds a reference, and the
value is encrypted somewhere else.  Most values that need one already work that
way.  This note finds the values written literally, which nothing else reports:
they validate, they render, and they work.

It names the file and the field, and never the value.  A note that prints a
password to fix a printed password defeats itself.

=cut

sub note_plaintext_secrets {

    # Read the files as they are on disk, not through Cookbook: a merged view
    # cannot say which file to edit.
    my $dir = Trog::Config->dir;
    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- which of these a configuration actually has
    my @files = grep { -f } ( "$dir/recipes.yaml", glob("$dir/recipes.d/*.yaml") );

    my @found;
    foreach my $file (@files) {
        my $conf = eval { YAML::XS::Load( File::Slurper::read_binary($file) ) } or next;
        push( @found, map { { file => $file, at => $_ } } _plaintext_in( $conf, q{} ) );
    }
    return { ok => 1 } unless @found;

    my $listed = join( "\n", map { "    $_->{file}\n        $_->{at}" } @found );
    return { ok => 0, what => scalar(@found) . ' secret(s) are written into the configuration in the clear', fix => <<"FIX" };
$listed

Each of those is a value the secret store could be holding instead, so that what
is in the file is a reference and the thing itself is somewhere encrypted.  Most
of this installation already works that way.

Put it in the store and point at it:

    bin/add_secret --group GROUP --title TITLE -- 'the value'

then replace the value with secret:GROUP/TITLE/password.  add_secret will not
overwrite, so it is safe to run against a store that may already have one.

Rotate anything that has been sitting in a file long enough to have been read.
FIX
}

=head2 @paths = _plaintext_in($node, $path)

Returns the path of each value under C<$node> that is a secret written out, not
a reference.  C<$path> is the path of C<$node> itself.

It uses two tests, because neither one catches what the other catches.  The
common case is a field named for a password that holds something other than a
reference.  Also, any value that is a private key is a secret wherever it is.
So a key pasted into a field with another name is found too.

=cut

sub _plaintext_in {
    my ( $node, $path ) = @_;

    return map { _plaintext_in( $node->[$_], "$path\[$_]" ) } 0 .. $#$node                if ref $node eq 'ARRAY';
    return map { _plaintext_in( $node->{$_}, $path ? "$path.$_" : $_ ) } sort keys %$node if ref $node eq 'HASH';
    return () if ref $node || !$node;

    # A reference is not a secret.  Neither is a placeholder from bin/new_guest,
    # because new_config refuses to build from one.
    return ()      if $node =~ m/\Asecret:/;
    return ($path) if $node =~ m/-----BEGIN[ ][[:upper:] ]*PRIVATE[ ]KEY-----/;
    return ()      if $node eq Provisioner::Cookbook->PLACEHOLDER;

    my ($field) = $path =~ m/([^.\[\]]+)\z/;
    return () unless defined $field;

    # _file and _path name a location, not a secret: the key_file of backup
    # holds a filename such as "backup.rsa".
    return ()      if $field =~ m/_(?:file|path)\z/;
    return ($path) if $field =~ m/pass|secret|token|credential|(?:\A|_)key\z/;

    return ();
}

sub _readable {
    my ($path) = @_;
    return -r $path ? 1 : 0;    ## no critic (ValuesAndExpressions::ProhibitFiletest_rwxRWX) -- the only question is whether it can be read, and what reads it opens it itself
}

=head1 SEE ALSO

L<Trog::HV::Libvirt>, the backend that builds guests with libvirt.

L<Trog::HV::OpenStack>, the one that asks a cloud.

L<Trog::HV::Linode>, the one that buys a Linode for each guest.

L<Trog::HV::Cloud>, what every backend that builds by API has in common.

L<Trog::Machine>, which this is one of.

L<Trog::Hypervisors>, which chooses between several of these.

=cut

1;
