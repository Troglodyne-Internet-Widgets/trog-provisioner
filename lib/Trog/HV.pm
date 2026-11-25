package Trog::HV;

#ABSTRACT: the hypervisor we are provisioning against, whichever kind it is.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
no autovivification;
use parent 'Trog::Machine';

use Trog::Config();
use Trog::Local();
use Trog::Credentials();
use Trog::Secrets();
use Trog::Utils();
use Provisioner::Cookbook();
use Provisioner::Packager::Deb();
use File::Slurper();
use YAML::XS();

use File::Which();
use Time::Piece();
use List::Util qw{any uniq};
use Module::Runtime();
use Net::CIDR();
use Net::IP();
use Provisioner::Vars();

# The pool and the gateway of one static adapter, by its bridge.  See NIC_KEY.
our $NIC_KEY = qr/\A (?:ip_pool|ip_addresses|gateway|prefix) _ (.+) \z/;

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

=item * C<client_module>, the API client this backend talks to its hypervisor
through, and the version of it that matters.  See L</$module = $hv-E<gt>require_client>.

=item * C<capacity>, in the form that L</shortfalls(%needs)> and
L</headroom(%needs)> read: a hash with C<memory_mb>, C<memory_free>,
C<memory_committed>, C<cpus>, C<cpus_allocatable>, C<cpus_committed>,
C<cpus_free>, C<disk_free> and C<guests>.  A backend that holds the guests
of one block apart from the rest of the hypervisor, as a libvirt
C<partition> does, gives the CPU keys and C<guests> of that share, its name
as C<partition>, and the same keys for the whole hypervisor as C<host>.  If
the share has a budget of memory, its memory keys are those of the share too,
and C<host> has the memory keys of the whole hypervisor.  A guest must then
fit in both.

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

=item * C<image_for_distro($distro, $release)>, what this hypervisor boots a
guest of that distribution and release from: a URL, a Glance image, a Linode
image.  Without C<$release>, the release that the distro recipe pins.  The
domain decides the release, and every kind of hypervisor answers for the same
pair.  F<bin/new_config> writes the answer into F<provision.conf>
as C<image>.  Dies when this hypervisor has no image for it.

=item * C<inspection_address($domain)>, the address at which a person reaches a
built guest to look at it, for the scripts that collect its logs or ask it
something.  It works when the build did not, which is when it is wanted.

=item * C<nat_address($domain)> and C<on_nat_network>: the address at which
this machine reaches a guest that got no address from the pool, or undef when it
cannot reach one, and whether it can reach such a guest at all.  See
L<Provisioner::IPPool/offers>.  Only a backend that does not manage addresses
has such a guest.

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

=item * C<set_reverse_dns>, if the hypervisor holds public addresses and lets
us set their reverse records.  See L</$address = $hv-E<gt>set_reverse_dns($domain, $name)>.

=item * C<builds_by_api> and C<manages_addresses>.  L<Provisioner::Recipe::ubuntu>,
F<bin/new_config> and L<Provisioner::IPPool> branch on these, not on a class
name.  They are only for where the two kinds take different paths: a guest
defined from XML or requested from a service, an address that we allocate or one
that we receive.  They are not for a step that one kind does not need.  The
three methods above are for that.  Both are false here.

=item * C<preflight_checks> and C<preflight_notes>, and the checks
C<check_reachable> and C<check_transfer_ip>.  See L</PREFLIGHT>, which also has
C<preflight_block_checks> -- answered here, and worth overriding by a backend
that can say something about a block without contacting anything.

=back

This class declares each method in the list that it does not answer itself.
That declaration dies, and names the backend and the missing method.  So a new
backend that leaves one out gets a clear error at the call, not "Can't locate
object method" from somewhere in F<bin/provision>.

If a method means nothing to a backend, the backend must die and say so.  It
must not return an undef that the caller carries somewhere else before it fails.

=for Pod::Coverage config_keys marker client_module annihilate_domain revert_snapshot inspection_address nat_address on_nat_network image_for_distro

=head1 CLASS METHODS

=cut

=head2 new(%opts)

=over 4

=item opts - HashRef - the constructor options of a backend, the limits under
L</PLACEMENT>, and C<name>

=back

Build or return the hypervisor.

If no option is set, it returns the instance built earlier in the process.  If
there is none, it builds a local one.  If options are set, it builds a new
hypervisor and makes I<that> the instance from then on.  So the configuration
is read only once.

The options are the constructor options of each backend (see C<config_keys>),
the limits under L</PLACEMENT>, and C<name>.  An option with a false value
(undef, empty or 0) is dropped.  So callers can pass unset command line options
straight through.

Returns Trog::HV, an instance of the backend.  Dies as C<candidate> does.

    my $hv = Trog::HV->new( uri => 'qemu+ssh://root@hv1.example.test/system' );

=cut

sub new {
    my ( $class, %opts ) = @_;

    # An option that is not set is not a request for a different hypervisor,
    # so a call that passes none gets the current one.
    my $current = Trog::HV->kept();
    return $current if $current && !any { $opts{$_} } keys %opts;

    return $class->candidate(%opts)->activate();
}

=head2 activate

Make this hypervisor the one that C<new> returns from now on.

Returns Trog::HV, this object, so calls can chain.

    my $hv = Trog::HV->candidate(%opts)->activate();

=cut

sub activate {
    my ($self) = @_;
    return Trog::HV->keep($self);
}

=head2 candidate(%opts)

=over 4

=item opts - HashRef - the options that C<new> takes

=back

Build a hypervisor and return it, but do not make it the current one.

Returns Trog::HV, an instance of the backend.

C<new> is a singleton because almost every caller wants the one hypervisor of
this run.  L<Trog::Hypervisors> is the exception.  It holds several hypervisors
at once to compare them, and only the winner becomes current.  Takes the same
options as C<new>.  Dies where C<backend_for> or the C<build> of the backend
dies.

Also dies when the options name the adapters of a guest, C<dhcp_nics>,
C<static_nics> or a key of L</NIC_KEY>, and the backend does not read
C<static_nics>.  C<options_from_block> reads the keys of every backend, so a
cloud block that names them would otherwise be built as if it did not, and its
guests would get none of the adapters or addresses that it asks for.

    my $hv = Trog::HV->candidate( uri => 'qemu+ssh://root@hv1.example.test/system' );

=cut

sub candidate {
    my ( $class, %opts ) = @_;

    my %given = map { $_ => $opts{$_} } grep { $opts{$_} } keys %opts;

    # Called on a backend class, use that backend.  Called on this class, choose one.
    my $backend = $class eq __PACKAGE__ ? $class->backend_for(%given) : $class;

    my %reads    = $backend->config_keys;
    my @nic_keys = sort grep { $_ eq 'dhcp_nics' || $_ eq 'static_nics' || m/$NIC_KEY/ } keys %given;
    die join( ', ', @nic_keys ) . ' for ' . ( $given{name} // $backend->marker_key ) . " name the adapters of a guest on bridges of the hypervisor, and their addresses, and $backend gives its guests the adapters and the addresses of its service.  Remove them from the block.\n"
      if @nic_keys && !$reads{static_nics};

    return $backend->build(%given);
}

=head2 backends

Returns the class name of every backend, as a list of Str, and loads each one.
Dies as C<require> does when a backend does not load.

    my @classes = Trog::HV->backends;

=cut

sub backends {
    my ($class) = @_;

    my @backends = map { __PACKAGE__ . "::$_" } qw{Libvirt OpenStack Linode SolusVM};

    # Loaded with require here, not with use at the top: each backend is a
    # subclass of this class, so a load at compile time makes a cycle.
    foreach my $backend (@backends) {
        Module::Runtime::require_module($backend);
    }

    return @backends;
}

=head2 backend_for(%opts)

=over 4

=item opts - HashRef - the options that C<new> takes

=back

Returns Str, the backend class that these options ask for: the one whose
C<marker> option is set, or L<Trog::HV::Libvirt> when none is.  Dies if more
than one is.

    my $class = Trog::HV->backend_for( uri => 'qemu+ssh://root@hv1.example.test/system' );

This is the one seam.  Everything else about another kind of hypervisor is a
subclass, and this method decides which subclass you get.

=cut

sub backend_for {
    my ( $class, %opts ) = @_;

    # A cloud has a name, a libvirt hypervisor has a URI, and a Linode account
    # has a token.  A configuration that names two cannot be satisfied, so do
    # not choose one of them.
    my @backends = $class->backends;
    my @named    = grep { local ($_) = $_; $opts{ $_->marker } } @backends;

    die 'A hypervisor is one of ' . join( ', ', map { local ($_) = $_; $_->marker_key } @backends ) . ', and this has ' . join( ' and ', map { local ($_) = $_; $_->marker_key } @named ) . ".\n"
      if @named > 1;

    return $named[0] // __PACKAGE__ . '::Libvirt';
}

=head2 marker_key

The F<hypervisors.conf> key of a backend's C<marker>, which is how a person
writing the file knows it.

Returns Str, the key.  Dies as C<config_keys> and C<marker> do, which is when
it is asked of this class and not of a backend.

    my $key = Trog::HV::Linode->marker_key;

=cut

sub marker_key {
    my ($class) = @_;

    my %in_file = $class->config_keys;
    return $in_file{ $class->marker };
}

=head2 $module = $hv->require_client

Loads the API client of this backend.

Returns Str, the name of the client module.

Each backend reaches its hypervisor through one client: L<Sys::Virt>,
L<OpenStack::MetaAPI>, L<Linode::API>.  Each of those is an optional dependency,
installed where an installation has that kind of hypervisor configured, so the
load is here rather than at the top of the backend.  A fleet of clouds runs
without libvirt's client, and a fleet of machines runs without either cloud's.

Call it from whatever builds the client, so a missing one is reported before any
work is attempted.  Dies naming the hypervisor, the client, why it would not
load, and the command that installs it.

A backend class answers it too, for a caller that wants to know whether a client
is there without building a hypervisor to ask.  F<bin/preflight> does that for
every block in F<hypervisors.conf>, before a run.

    my $module = $hv->require_client;

=cut

sub require_client {
    my ($self) = @_;

    my ( $module, $want ) = $self->client_module;
    my $loaded = eval {
        Module::Runtime::require_module($module);
        $module->VERSION($want) if defined $want;
        1;
    };
    return $module if $loaded;

    # The list of every directory perl looked in is the bulk of that message
    # and none of the answer, which is on the line above it.
    my $why = $@ =~ s/\s* [(] \@INC [ ] entries [ ] checked: .* /\n/srx;

    my $spec = defined $want ? "$module~$want" : $module;
    my $who  = ref $self     ? $self->describe : $self;
    die "$who talks to its hypervisor through $module, which will not load here:\n" . "  $why" . "    cpanm $spec\n";
}

=head2 options_from_block($block)

=over 4

=item block - HashRef - one block of F<hypervisors.conf>

=back

Turn one F<hypervisors.conf> block into constructor options.  A key that the
block does not set is left out.

Returns the options, as a list of pairs.  Dies as C<backends> does.

    my %opts = Trog::HV->options_from_block( { libvirt_uri => 'qemu:///system' } );

It reads the keys of every backend, because the content of a block decides
which backend it describes.  So all keys must be read before that decision.
Each backend names its own keys in C<config_keys>.  This class reads the
placement limits, because placement belongs to this class, and C<transfer_ip>
and C<transfer_port>, because every kind of hypervisor has guests that fetch
from us.  It reads C<network>, C<resolvers> and C<cache>, because what a guest
can reach depends on where it is, and each key of L</NIC_KEY>, because the pool and the
gateway of each static adapter of a guest are on the network of its bridge.

=head2 NIC_KEY

The keys of a block that name the pool, the gateway and the prefix of one static
adapter of a guest: C<ip_pool_NIC>, C<ip_addresses_NIC>, C<gateway_NIC> and
C<prefix_NIC>, where NIC is the bridge of the adapter in C<static_nics>.  See
L</nic_pool($nic)>, L</nic_gateway($nic)> and L</nic_prefix_length($nic)>.

=head2 replaced_keys($block)

=over 4

=item block - HashRef - a block of F<hypervisors.conf> or the settings of
F<provision.conf>

=back

The keys of C<$block> that name the adapters and the pool of a guest in the
way that C<dhcp_nics> and C<static_nics> replaced.  L<Trog::Hypervisors>
refuses a block that has one, and so does C<from_config>.

Returns each such key with what replaced it, as a list of pairs of Str, or an
empty list for a block that names none.

    my %replaced = Trog::HV->replaced_keys( { bridge_device => 'br0' } );

=cut

my @LIMIT_KEYS = qw{reserve_memory reserve_cpus reserve_disk max_guests cpu_overcommit};

# Where a guest of this hypervisor reaches us, which is any backend's question.
my @TRANSFER_KEYS = qw{transfer_ip transfer_port};

# The network of the guests of this hypervisor, and what they reach.  See
# network, configured_resolvers and configured_cache.
my @NETWORK_KEYS = qw{network resolvers cache};

# What took the place of each key of the two adapters that a guest used to
# have.  See replaced_keys.
my %REPLACED = (
    virbr_device   => 'dhcp_nics, whose first bridge takes the lease',
    bridge_device  => 'static_nics',
    nics           => 'dhcp_nics and static_nics',
    gateway        => 'gateway_NIC, for the bridge NIC of static_nics',
    pool_cidr      => 'ip_pool_NIC, for the bridge NIC of static_nics',
    pool_addresses => 'ip_addresses_NIC, for the bridge NIC of static_nics',
);

sub replaced_keys ( $, $block ) {
    return map { $_ => $REPLACED{$_} } sort grep { defined $block->{$_} } keys %REPLACED;
}

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

    $opts{$_} = $block->{$_} for grep { defined $block->{$_} } @LIMIT_KEYS, @TRANSFER_KEYS, @NETWORK_KEYS, grep { m/$NIC_KEY/ } keys %$block;

    return %opts;
}

=head2 from_config($config, %override)

=over 4

=item config - Config::Simple|HashRef|Undef - the configuration, or a false
value for every default

=item override - HashRef - values that win over the file

=back

Build the hypervisor from a L<Config::Simple> object through C<new>.  A value in C<%override>, for example from the
command line, wins over the
file.  An empty override counts as not given, as it does in C<new>, so the file
still answers for it.  A false C<$config> is allowed, and means that every value
takes its default.

It reads every key that a backend names in C<config_keys>: C<libvirt_uri> for
C<uri>, and the rest under their own names, and each key of L</NIC_KEY>.

Returns Trog::HV, the hypervisor, as C<new> returns it.  Dies on a key of
C<replaced_keys>, with what to name instead, and as C<new> does.

    my $hv = Trog::HV->from_config( $config, uri => $uri );

=cut

sub from_config {
    my ( $class, $config, %override ) = @_;

    # The keys of every backend, because what a configuration contains decides
    # which backend it describes.
    my %key = map { local ($_) = $_; $_->config_keys } $class->backends;

    my %said     = map { local ($_) = $_; $_ => $class->config_value( $config, $_ ) } $class->config_keys_of($config);
    my %replaced = $class->replaced_keys( \%said );
    die 'The configuration names ' . join( ', ', map { "$_, which is now $replaced{$_}" } sort keys %replaced ) . ".  See The adapters of a guest in docs/CONFIGURATION.md.\n" if %replaced;

    $key{$_} = $_ for grep { m/$NIC_KEY/ } keys %said;
    return $class->new( map { local ($_) = $_; $_ => ( $override{$_} || $class->config_value( $config, $key{$_} ) ) } keys %key );
}

=head2 config_keys_of($config)

=over 4

=item config - Config::Simple|HashRef|Undef - a configuration of a file with
no blocks, or nothing

=back

Returns the names of the keys that C<$config> sets, as a list of Str, or an
empty list for no configuration.

    my @keys = Trog::HV->config_keys_of($config);

=cut

sub config_keys_of ( $, $config ) {
    return () unless $config;
    return keys %$config if ref $config eq 'HASH';
    return map { s/\A default [.]//r } keys %{ $config->vars };
}

=head2 config_value($config, $key)

=over 4

=item config - Config::Simple|HashRef|Undef - the configuration

=item key - Str - the name of the key

=back

Returns Str|Undef, one value from a configuration, which is a
L<Config::Simple> object or a plain hashref.  A key that is given more than once returns its
first value.  Returns undef when there is no configuration, no such key, or an
empty value.

    my $uri = Trog::HV->config_value( $config, 'libvirt_uri' );

=cut

sub config_value {
    my ( $class, $config, $key ) = @_;
    return undef unless $config;

    my $value = ref $config eq 'HASH' ? $config->{$key} : $config->param($key);
    $value = $value->[0] if ref $value eq 'ARRAY';
    return ( length $value ) ? $value : undef;    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a setting of "0" is still a setting
}

=head2 forget()

Drops the hypervisor that C<new> returns, as L<Trog::Machine/keep($object),
kept, forget> says, so that the next C<new> or C<Trog::Hypervisors> choice
makes a new one.  F<bin/provision> calls it before each guest it builds,
because the guests of one run can be on different hypervisors.

=cut

=head2 setting($name)

=over 4

=item name - Str - the key in the block

=back

One value from the block of this hypervisor in F<hypervisors.conf>, with a
C<secret:> reference resolved.

Returns Str|ArrayRef|Undef: the value, an array reference when the block gives
the key more than once, or undef when the block does not name it.

    my $token = $hv->setting('linode_token');

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
        Trog::Credentials->store_password(),
        $name => $value,
    );

    return $self->{_secrets}{$name} = $found{$name};
}

=head2 @items = $hv->setting_list($name)

=over 4

=item name - Str - the key in the block

=back

One value from the block, as C<setting> gives it, read as a list.  The block
separates the items with commas or spaces, and L<Config::Simple> already makes a
list of a value with a comma in it.

Returns the items, as a list of Str, or an empty list when the block does not
name it.

    my @resolvers = $hv->setting_list('resolvers');

=cut

sub setting_list ( $self, $name ) {
    my $said = $self->setting($name) // return;
    return grep { $_ ne q{} } map { split m/[\s,]+/ } ( ref $said eq 'ARRAY' ? @$said : $said );
}

=head1 IDENTITY

=head2 name

Returns the name of this hypervisor in F<hypervisors.conf>, or undef if it did
not come from there.

=cut

=head2 configured_transfer_ip, configured_transfer_port

The address and the ssh port of this machine that a guest of this hypervisor
fetches its payload from, when its block in F<hypervisors.conf> names them, or
undef.  They win over the C<_global> of F<recipes.yaml>, because the answer
depends on where the guest is.  A guest on a machine of ours reaches us across
our own network.  A guest on a cloud reaches us through the gateway, at an
address and a port forwarded past it.

Returns Str|Undef, the address, and the port.

Dies when C<transfer_port> is not a port number.

    my $ip   = $hv->configured_transfer_ip;
    my $port = $hv->configured_transfer_port;

=cut

sub configured_transfer_ip ($self) { return $self->setting('transfer_ip') }

=head2 network

The name of the network that the guests of this hypervisor are on, from
C<network> in its block of F<hypervisors.conf>, or empty when the block names
none.  The guests of two hypervisors on one network can reach each other, and
the guests of two on different networks cannot.  Every block that names none is
on the one empty network, so a fleet that names no network is one network.

L<Trog::Hypervisors/select_for> places a guest that needs another guest up on
the network of that guest.  For example, the hypervisors of a home network
share a label, and a block for a cloud region has a label of its own.

Returns Str, the name, or the empty string.

    my $network = $hv->network;

=cut

sub network ($self) { return $self->setting('network') // q{} }

=head2 configured_resolvers

The nameservers that a guest of this hypervisor uses, from C<resolvers> in its
block of F<hypervisors.conf>, as a list of addresses.  The block separates them
with commas.  Empty when the block names none, and C<bin/new_config> refuses a
guest of such a hypervisor.

Each block names its own, because a guest on a cloud cannot reach the gateway
of a home network.

Returns the addresses, as a list of Str.  Dies on a value that is not an
address.

    my @resolvers = $hv->configured_resolvers;

=cut

sub configured_resolvers ($self) {
    my @resolvers = $self->setting_list('resolvers') or return;
    foreach my $resolver (@resolvers) {
        Net::IP->new($resolver) or die "resolvers for " . ( $self->name // $self->describe ) . " names '$resolver', which is not an address\n";
    }
    return @resolvers;
}

=head2 configured_cache

The fetch cache that the guests of this hypervisor provision through, from
C<cache> in its block of F<hypervisors.conf>, as a domain or an IPv4 address, or
undef when the block names none.  Then its guests download from upstream.

Each block names its own, because a guest reaches only a cache on its own
network, or through its NAT.  A runner keeps an ip pool of its own, which does
not hold the cache of the fleet, so its block names the cache by address.
L<Provisioner::DistroRecipe/cache_address> turns the value into the address
that a guest points the hosts it downloads from at.

Returns Str|Undef, the domain or address of the cache.

    my $cache = $hv->configured_cache;

=cut

sub configured_cache ($self) { return $self->setting('cache') }

=head2 static_nics

The bridges of the static adapters of a guest of this hypervisor, from
C<static_nics> in its block of F<hypervisors.conf>, in order.  Each one gets an
address from its own pool, see C<nic_pool>.  The first one gets the address of
the guest, the one in C<ipmap>, its records and its default route.  Empty for a
block that names none, and for every hypervisor of a service, which gives its
guests their addresses.

Returns the bridges, as a list of Str.

    my @bridges = $hv->static_nics;

=head2 address_nic

The first of C<static_nics>, whose address is the address of the guest.

Returns Str|Undef, the bridge, or undef when there is none.

    my $bridge = $hv->address_nic;

=cut

sub static_nics ($self) { return $self->setting_list('static_nics') }
sub address_nic ($self) { my ($first) = $self->static_nics; return $first }

=head2 nic_pool($nic)

=over 4

=item nic - Str - the bridge of the adapter

=back

The addresses that a static adapter on the bridge C<$nic> gets, as a bin of
L<Provisioner::IPPool/BINS>.

Returns HashRef, with C<cidr> from C<ip_pool_NIC> and C<addresses> from
C<ip_addresses_NIC> in the block of this hypervisor, each an array reference of
Str.  A key that the block does not name is left out.

    my $pool = $hv->nic_pool('br0');

Two blocks that name the same pool for the same bridge share its addresses in
F<ips.db>.  See L<Provisioner::IPPool/guest_pools>.

=head2 static_pools

The pool of each of C<static_nics>.

Returns HashRef, from each bridge to what C<nic_pool> gives.

    my $pools = $hv->static_pools;

=cut

sub nic_pool ( $self, $nic ) {
    my %pool;
    my %key = ( cidr => "ip_pool_$nic", addresses => "ip_addresses_$nic" );
    foreach my $part ( sort keys %key ) {
        my @items = $self->setting_list( $key{$part} );
        $pool{$part} = \@items if @items;
    }
    return \%pool;
}

sub static_pools ($self) {
    return { map { local ($_) = $_; $_ => $self->nic_pool($_) } $self->static_nics };
}

=head2 nic_gateway($nic)

=over 4

=item nic - Str - the bridge of the adapter

=back

The gateway of the subnet of the static adapter on the bridge C<$nic>, from
C<gateway_NIC> in the block of this hypervisor.  The first of C<static_nics>
routes everything through it.

Returns Str|Undef, the address, or undef when the block names none.  Dies on a
value that is not an IPv4 address.

    my $gateway = $hv->nic_gateway('br0');

=cut

sub nic_gateway ( $self, $nic ) {
    my $gateway = $self->setting("gateway_$nic") // return;
    my $ip      = Net::IP->new($gateway);
    die "gateway_$nic for " . ( $self->name // $self->describe ) . " is '$gateway', which is not an IPv4 address\n"
      unless $ip && $ip->version == 4 && $ip->size == 1;
    return $gateway;
}

=head2 nic_prefix_length($nic)

=over 4

=item nic - Str - the bridge of the adapter

=back

The length of the prefix of the network of the bridge C<$nic> of
C<static_nics>, which a static address on it gets unless C<ip_addresses_NIC>
writes one of its own.  It is C<prefix_NIC> when the block names it.  Otherwise
it is the prefix of C<ip_pool_NIC>, when that is one block and holds
C<gateway_NIC>, because then the pool is the network itself.

Dies when neither is so.  A pool that is a part of a larger network, such as
C<10.0.0.64/26> on a network whose gateway is C<10.0.0.1>, does not say how
large that network is, and a guest given the prefix of its pool could not
reach its gateway.  Also dies on a C<prefix_NIC> that is not from 8 to 30.

Returns Int, the length.

    my $length = $hv->nic_prefix_length('br0');

=head2 address_prefix($nic, $address)

=over 4

=item nic - Str - the bridge of the adapter

=item address - Str - the static address, without a prefix

=back

The length of the prefix that the static address C<$address> on the bridge
C<$nic> gets in the network configuration of a guest: the one that
C<ip_addresses_NIC> writes after it, such as C<10.0.0.5/26>, or else
C<nic_prefix_length>.

Returns Int, the length.  Dies as C<nic_prefix_length> does.

    my $length = $hv->address_prefix( 'br0', '192.0.2.5' );

=cut

sub nic_prefix_length ( $self, $nic ) {
    my $who = $self->name // $self->describe;
    if ( defined( my $prefix = $self->setting("prefix_$nic") ) ) {
        die "prefix_$nic for $who is '$prefix', which is not a length of a prefix from 8 to 30\n" unless is_prefix_length($prefix);
        return $prefix;
    }

    my @blocks  = @{ $self->nic_pool($nic)->{cidr} // [] };
    my $gateway = $self->nic_gateway($nic);
    my $pool    = @blocks == 1 ? Net::IP->new( $blocks[0] ) : undef;
    my $holds   = $pool && defined $gateway && ( Net::IP->new($gateway)->overlaps($pool) // 0 ) == $Net::IP::IP_A_IN_B_OVERLAP;
    return $pool->prefixlen if $holds;

    die "The network of $nic for $who has no prefix that its block says.  ip_pool_$nic is not one block that holds gateway_$nic, so it is a part of a larger network, and a guest given the prefix of the pool could not reach its gateway.  Name the length of the prefix of the network of $nic: prefix_$nic = 24, for example.\n";
}

=head2 $cidr = Trog::HV::network_of($address, $prefix)

=over 4

=item address - Str - an IPv4 address

=item prefix - Int - the length of the prefix of the network

=back

Returns Str, the block of the network of the length C<$prefix> that holds
C<$address>, such as C<192.0.2.0/24> for C<192.0.2.1> and 24.

    my $cidr = Trog::HV::network_of( '192.0.2.1', 24 );

=cut

# addr2cidr gives each block that holds the address, from the /32 down to the
# /0.
sub network_of ( $address, $prefix ) { return ( Net::CIDR::addr2cidr($address) )[ 32 - $prefix ] }

=head2 $bool = Trog::HV::is_prefix_length($prefix)

=over 4

=item prefix - Str|Undef - what to judge

=back

Whether C<$prefix> is the length of the prefix of a network of guests: a whole
number from 8 to 30.  A /31 and a /32 have no address for a host beside the
gateway.

Returns Bool, 1 when it is and 0 when it is not.

    my $ok = Trog::HV::is_prefix_length(24);

=cut

sub is_prefix_length ($prefix) { return ( $prefix // q{} ) =~ m/\A \d{1,2} \z/ && $prefix >= 8 && $prefix <= 30 ? 1 : 0 }

sub address_prefix ( $self, $nic, $address ) {
    my ($written) = map { m{\A \Q$address\E / (\d+) \z} ? $1 : () } @{ $self->nic_pool($nic)->{addresses} // [] };
    return $written // $self->nic_prefix_length($nic);
}

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

    my $dir = $hv->domain_dir;

=cut

sub domain_dir ($self) { return $self->{domain_dir} // $self->default_domain_dir }

=head2 default_domain_dir

Returns the directory for domains when nothing else sets one: the C<basedir>
in the C<_global> of C<_base> in F<recipes.yaml>, where C<bin/new_config>
writes the directory of each domain, or F</opt/domains> when that names none.
It reads the file at each call.

It is a class method, so C<bin/provision> and C<bin/restore> can call it before
they have a hypervisor.  C<bin/provision> needs the path to find
F<provision.conf>, and F<provision.conf> names the hypervisor.  Keep the default
here only, so that the two cannot disagree.

    my $dir = Trog::HV->default_domain_dir;

=cut

sub default_domain_dir {
    my $conf = eval { YAML::XS::Load( File::Slurper::read_binary( Trog::Config->path('recipes.yaml') ) ) };
    my $base = ref $conf eq 'HASH' ? $conf->{_base}{_global}{basedir} : undef;
    return $base // '/opt/domains';
}

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

Returns Bool, 0 here.

    my $by_api = $hv->builds_by_api;

=head2 manages_addresses

Whether the hypervisor gives its guests their addresses, so that we do not
choose one out of the address pool.

Returns Bool, 0 here.

    my $managed = $hv->manages_addresses;

If it does, the pool has nothing to allocate and nothing of ours to collide
with.  L<Provisioner::IPPool> does not sweep that hypervisor, because its
addresses do not come from the pool.

=cut

sub builds_by_api     { return 0 }
sub manages_addresses { return 0 }

=head2 reserve_guest(%spec)

=over 4

=item spec - HashRef - C<name>, the guest, C<size>, and for some backends
C<region>

=back

Makes the guest C<name> empty, so that it has its addresses before its
configuration is written.

Returns Bool: true when the backend reserved the guest, and false where it
cannot, which is the 0 that it returns here.

C<bin/new_config> calls it for C<bin/provision>, on a backend that
C<manages_addresses>, for a guest that does not exist yet.  Then it reads the
address of the guest, and C<provision_guest> builds the image onto the guest
that is there.  Without it, the address is known only after the build, so the
configuration names none.

C<size> is the value of the C<size_key> of the guest, and a backend can also
take C<region>.

    my $reserved = $hv->reserve_guest( name => 'vm.example.test', size => $size );

=head2 is_reservation($domain)

=over 4

=item domain - Str - the name of the guest

=back

Returns Bool: true when the guest of C<$domain> is as C<reserve_guest> left it,
with nothing on it to snapshot or to salvage.  0 here.

    my $empty = $hv->is_reservation('vm.example.test');

=cut

sub reserve_guest  { return 0 }
sub is_reservation { return 0 }

=head2 @actions = $hv->debug_actions()

The actions of F<bin/debug_boot> that this backend can do, named as the options
are: C<console>, C<fetch>, C<hold>, C<shot>, C<vnc>, C<keys>, C<restore>,
C<cat>, C<ls>, C<single>.

Empty by default, so a backend that says nothing debugs nothing and the tool
refuses before it touches the guest.  A backend that names an action
implements the methods below that the action uses.

Returns the names, as a list of Str.

    my @actions = $hv->debug_actions();

=cut

sub debug_actions { return () }

=head2 $restarted = $hv->console_capture(@args)

=over 4

=item args - ARRAY - the name of the guest, then C<wait =E<gt> $seconds>

=back

Makes the console of the guest readable by C<console_output>.

A backend that has to redirect the console restarts the guest, waits
C<$seconds> for it to boot, and returns true.  A backend that keeps the console
of every guest does nothing and returns false.

Returns Bool, whether it restarted the guest.  Here it dies, because the
backend does not implement it.

    my $restarted = $hv->console_capture( 'vm.example.test', wait => 60 );

=head2 $text = $hv->console_output($domain)

=over 4

=item domain - Str - the name of the guest

=back

Returns Str|Undef, what the console of C<$domain> has printed, or undef if
there is none to read.  Here it dies, because the backend does not implement
it.

    my $text = $hv->console_output('vm.example.test');

=head2 ($advice, $value) = $hv->vnc_access($domain)

=over 4

=item domain - Str - the name of the guest

=back

How to reach the display of C<$domain>.

Returns two Str: C<$advice>, text for the operator, which names what stands
between them and the display, such as an ssh tunnel, and C<$value>, the one
thing a caller can act on: a port, or a URL.

Dies if the guest has no display, and here, because the backend does not
implement it.

    my ( $advice, $value ) = $hv->vnc_access('vm.example.test');

=cut

=head1 WHAT EVERY BACKEND ANSWERS

This class declares these methods, so a backend that leaves one out gets an
error that names the method.  See L</WHAT A BACKEND HAS TO PROVIDE> for the
purpose of each.

Each of these dies here, naming the backend and the method, because the backend
does not implement it.

=head2 build(%opts)

=over 4

=item opts - HashRef - the options that C<new> takes, those of the backend's
C<config_keys> among them

=back

Called on the backend class, makes a hypervisor of that kind.  C<candidate>
calls it.

Returns Trog::HV, the new instance of the backend.  A backend dies when the
options do not make a hypervisor of its kind.

    my $hv = Trog::HV::Libvirt->build( uri => 'qemu:///system' );

=head2 domain_exists($name)

=over 4

=item name - Str - the name of the guest

=back

Returns Bool: 1 if the hypervisor has a guest called C<$name>, and 0 if it has
not.

    my $exists = $hv->domain_exists('vm.example.test');

=head2 guest_names

Every guest that the backend has.  An orphan sweep uses it to tell that a
directory belongs to a guest that still exists.

Returns the names, as a list of Str.

    my @names = $hv->guest_names;

=head2 guest_ssh_ip($config)

=over 4

=item config - Config::Simple - the F<provision.conf> of the guest

=back

The address at which this machine reaches a built guest over ssh.  A backend
may take a second argument, the address of a lease, as
L<Trog::HV::Libvirt> does.

Returns Str, the address.  A backend dies when the guest has no address.

    my $ip = $hv->guest_ssh_ip($config);

=head2 snapshot_names($domain)

=over 4

=item domain - Str - the name of the guest

=back

Returns the names of the snapshots of the guest, newest first, as a list of
Str.

    my @snapshots = $hv->snapshot_names('vm.example.test');

=head2 snapshot_current_name($domain)

=over 4

=item domain - Str - the name of the guest

=back

Returns Str|Undef, the name of the snapshot that the guest is on, or undef
when there is none.

    my $current = $hv->snapshot_current_name('vm.example.test');

=head2 create_snapshot(@args)

=over 4

=item args - ARRAY - the name of the guest, the name of the snapshot, then the
options as pairs: C<disk_only> and C<leave_down>, which a cloud ignores

=back

Takes a snapshot of the guest under that name.  C<snapshot_before_rebuild>
calls it.

Returns Bool, true when the snapshot was taken.  A backend warns and returns
false when it could not take it.

    my $ok = $hv->create_snapshot( 'vm.example.test', 'before-change', disk_only => 1 );

=head2 clear_guest(@args)

=over 4

=item args - ARRAY - the name of the guest, then C<keep_disk =E<gt> 1> to
leave the disk of the guest in place

=back

Removes what must go before a guest of that name can be made.  See
L</WHAT A BACKEND HAS TO PROVIDE>.

Returns Bool, true when the guest is clear.

    $hv->clear_guest( 'vm.example.test', keep_disk => 0 );

=head2 rollback_possible(@args)

=over 4

=item args - ARRAY - the name of the guest, then C<capacity =E<gt> $bytes>, the
size that the rebuild asks for

=back

Whether a snapshot taken now is still there to go back to after the rebuild.
See L</WHAT A BACKEND HAS TO PROVIDE>.

Returns Bool, 1 when it is and 0 when it is not.

    my $ok = $hv->rollback_possible( 'vm.example.test', capacity => $bytes );

=head2 provision_guest(@args)

=over 4

=item args - ARRAY - the F<provision.conf> of the guest as a L<Config::Simple>
object, the NoCloud files of the seed as a hash reference, then the options as
pairs, such as C<reuse> and C<settings>

=back

Makes the guest from the seed that C<bin/provision> wrote.

Returns Str, the address that the guest came up at.  A backend dies when it
cannot make the guest.

    my $ip = $hv->provision_guest( $config, \%seed, reuse => 0 );

=head2 would_provision(@args)

=over 4

=item args - ARRAY - the F<provision.conf> of the guest as a L<Config::Simple>
object, then the options as pairs, as C<provision_guest> takes them

=back

For a dry run: prints what C<clear_guest> and C<provision_guest> would do, and
does not do it.

Returns Str, the address of a guest that exists, or what stands for one that
does not.

    my $ip = $hv->would_provision( $config, reuse => 1 );

=head2 prepare_host($virtiofs)

=over 4

=item virtiofs - Str - our copy of F<virtiofs-better>

=back

Does what the hypervisor needs before a guest can be built on it.  C<$virtiofs>
is our copy of F<virtiofs-better>, for a backend whose guests run in a qemu
process that uses it.

Returns Bool, true when the hypervisor is ready.

    $hv->prepare_host($virtiofs);

=head2 release_seed($domain)

=over 4

=item domain - Str - the name of the guest

=back

Called after the guest reports that cloud-init finished, and not before.  Until
then, the guest can still be reading its seed.

Returns Bool, true when the seed is released.

    $hv->release_seed('vm.example.test');

=head2 guest_volumes($domain)

=over 4

=item domain - Str - the name of the guest

=back

Returns the volumes that belong to this guest alone, which we delete after the
guest is gone, as a list of Str.  Never the base image, because every other
guest is built on it.

    my @volumes = $hv->guest_volumes('vm.example.test');

=head2 @removed = $hv->prune_base_images()

Removes the base images that nothing is built on any more.  Call it after a
disk has gone.  A base image that is not the newest of its kind stays while any
disk is backed by it.

Returns the names of the images it removed, as a list of Str.  A backend with
no base image returns an empty list.

    my @removed = $hv->prune_base_images();

=cut

=head2 @globs = $hv->guest_disks()

The names that a guest here gives its disks, as udev C<KERNEL> globs, such as
C<vd*>.  The bus of a disk is a choice of the hypervisor, so the name is too.
L<Provisioner::Recipe::diskqueue> sets the queue of the disks that these
globs name.  A glob must not name a device that is not a disk of the guest,
such as the CD-ROM of a seed.

Returns the globs, as a list of Str.

    my @globs = $hv->guest_disks();

=head2 uri

Returns Str, the address of the hypervisor, as a message names it: a libvirt
connection URI, or the endpoint of the API of a service.

    my $uri = $hv->uri;

=head2 The libvirt nouns

C<define_domain>, C<cloudinit_iso>, C<eject_cdrom>, C<pool_path>,
C<pool_target>, C<base_image>, C<create_disk>, C<lease_ip>,
C<release_dhcp_lease>, C<guest_mac>, C<nic_slots>, C<nic_names> and C<has_tpm>
are about a guest that is built from files in a storage pool.
L<Trog::HV::Libvirt> answers them, and its documentation says what each does.
A backend with no such thing refuses each with the reason, as
L<Trog::HV::Cloud> does.

=for Pod::Coverage define_domain cloudinit_iso eject_cdrom pool_path pool_target base_image create_disk lease_ip release_dhcp_lease guest_mac nic_slots nic_names has_tpm

=head2 $hv->abstract($method)

=over 4

=item method - Str - the name of the method that the backend lacks

=back

Returns nothing.  Dies with an error that names the class of C<$hv>, C<$method>, and the class
that declares C<$method>, which is the class that calls this.  A class
declares a method that each of its subclasses has to provide with a sub that
calls this, so that a subclass that leaves it out gets that error and not
"method not found".

    sub capacity ( $self, @ ) { return $self->abstract('capacity') }

=cut

sub abstract ( $self, $method ) {
    my ($declared) = caller;
    die( ( ref($self) || $self ) . " does not implement $method, which every backend of $declared has to\n" );
}

sub build                 ( $self, @ ) { return abstract( $self, 'build' ) }
sub config_keys           ( $self, @ ) { return abstract( $self, 'config_keys' ) }
sub marker                ( $self, @ ) { return abstract( $self, 'marker' ) }
sub client_module         ( $self, @ ) { return abstract( $self, 'client_module' ) }
sub domain_exists         ( $self, @ ) { return abstract( $self, 'domain_exists' ) }
sub annihilate_domain     ( $self, @ ) { return abstract( $self, 'annihilate_domain' ) }
sub guest_names           ( $self, @ ) { return abstract( $self, 'guest_names' ) }
sub guest_ssh_ip          ( $self, @ ) { return abstract( $self, 'guest_ssh_ip' ) }
sub inspection_address    ( $self, @ ) { return abstract( $self, 'inspection_address' ) }
sub nat_address           ( $self, @ ) { return abstract( $self, 'nat_address' ) }
sub on_nat_network        ( $self, @ ) { return abstract( $self, 'on_nat_network' ) }
sub image_for_distro      ( $self, @ ) { return abstract( $self, 'image_for_distro' ) }
sub snapshot_names        ( $self, @ ) { return abstract( $self, 'snapshot_names' ) }
sub snapshot_current_name ( $self, @ ) { return abstract( $self, 'snapshot_current_name' ) }
sub create_snapshot       ( $self, @ ) { return abstract( $self, 'create_snapshot' ) }
sub revert_snapshot       ( $self, @ ) { return abstract( $self, 'revert_snapshot' ) }
sub prepare_host          ( $self, @ ) { return abstract( $self, 'prepare_host' ) }
sub release_seed          ( $self, @ ) { return abstract( $self, 'release_seed' ) }
sub guest_volumes         ( $self, @ ) { return abstract( $self, 'guest_volumes' ) }
sub clear_guest           ( $self, @ ) { return abstract( $self, 'clear_guest' ) }
sub prune_base_images     ( $self, @ ) { return abstract( $self, 'prune_base_images' ) }
sub rollback_possible     ( $self, @ ) { return abstract( $self, 'rollback_possible' ) }
sub provision_guest       ( $self, @ ) { return abstract( $self, 'provision_guest' ) }
sub would_provision       ( $self, @ ) { return abstract( $self, 'would_provision' ) }
sub console_capture       ( $self, @ ) { return abstract( $self, 'console_capture' ) }
sub console_output        ( $self, @ ) { return abstract( $self, 'console_output' ) }
sub vnc_access            ( $self, @ ) { return abstract( $self, 'vnc_access' ) }
sub uri                   ( $self, @ ) { return abstract( $self, 'uri' ) }
sub guest_disks           ( $self, @ ) { return abstract( $self, 'guest_disks' ) }
sub define_domain         ( $self, @ ) { return abstract( $self, 'define_domain' ) }
sub cloudinit_iso         ( $self, @ ) { return abstract( $self, 'cloudinit_iso' ) }
sub eject_cdrom           ( $self, @ ) { return abstract( $self, 'eject_cdrom' ) }
sub pool_path             ( $self, @ ) { return abstract( $self, 'pool_path' ) }
sub pool_target           ( $self, @ ) { return abstract( $self, 'pool_target' ) }
sub base_image            ( $self, @ ) { return abstract( $self, 'base_image' ) }
sub create_disk           ( $self, @ ) { return abstract( $self, 'create_disk' ) }
sub lease_ip              ( $self, @ ) { return abstract( $self, 'lease_ip' ) }
sub release_dhcp_lease    ( $self, @ ) { return abstract( $self, 'release_dhcp_lease' ) }
sub guest_mac             ( $self, @ ) { return abstract( $self, 'guest_mac' ) }
sub nic_slots             ( $self, @ ) { return abstract( $self, 'nic_slots' ) }
sub nic_names             ( $self, @ ) { return abstract( $self, 'nic_names' ) }
sub has_tpm               ( $self, @ ) { return abstract( $self, 'has_tpm' ) }

=head2 $hv->check_user_data($user_data)

=over 4

=item user_data - Str - the cloud-init payload

=back

Dies with the reason when this backend cannot hand the cloud-init payload
C<$user_data> to a guest, and returns true when it can.  F<bin/provision> asks
it before it snapshots or clears the guest, so a payload that cannot be sent
stops the run while the guest is as it was.

True here, because libvirt writes the seed to an ISO, which has no limit to
speak of.  A backend that sends the payload through an API with a limit
overrides it, as L<Trog::HV::Linode> does.

Returns Bool, 1 here.

    $hv->check_user_data( $seed{'user-data'} );

=cut

sub check_user_data { return 1 }

=head2 $name = $hv->snapshot_before_rebuild($domain, %opts)

=over 4

=item domain - Str - the name of the guest

=item opts - HashRef - C<capacity>, the size in bytes that the rebuild asks
for, which C<rollback_possible> uses

=back

Takes a snapshot just before a rebuild, as the rollback point.  Backends do not
override this method.

Returns Str|Undef: the name of the snapshot, or undef whenever the snapshot did
not happen.  That is when
C<rollback_possible> is false, or when C<create_snapshot> warns and returns
false.  The caller offers a returned name to an operator as the way back.  So a
name for a snapshot that does not exist is worse than no name.

The name holds the date and the time to the second.  An operator reads it back
out of the backend and types it at C<bin/restore>.  It has no colons, because
it goes onto a command line, and on libvirt into the snapshot XML too.  Nothing
sorts on it, because C<snapshot_names> sorts by creation time.

    my $name = $hv->snapshot_before_rebuild( 'vm.example.test', capacity => $bytes );

=cut

sub snapshot_before_rebuild {
    my ( $self, $domain, %opts ) = @_;

    return unless $self->rollback_possible( $domain, capacity => $opts{capacity} );

    my $name = 'before-reprovision-' . Time::Piece::localtime()->strftime('%Y-%m-%d-%H%M%S');

    # Disk only, and left down: the rebuild follows at once, so a memory image
    # and a restart are waste.  A cloud ignores both options.
    return $self->create_snapshot( $domain, $name, disk_only => 1, leave_down => 1 ) ? $name : undef;
}

=head2 $hv->rebuild_destroys_guest($domain, %opts)

=over 4

=item domain - Str - the name of the guest

=item opts - HashRef - C<capacity>, the size in bytes that the build asks for

=back

Whether a rebuild of this domain takes the existing guest apart, as opposed to
a build over it.

Returns Bool, 0 here: a backend that replaces the root disk of a server in
place keeps the server and its addresses, so nothing is lost.
L<Trog::HV::Libvirt> overrides it.  F<bin/provision> decides what to do about a
true answer.

    my $destroys = $hv->rebuild_destroys_guest( 'vm.example.test', capacity => $bytes );

=cut

sub rebuild_destroys_guest { return 0 }

=head2 $hv->clone_guest_disk($domain)

=over 4

=item domain - Str - the name of the guest

=back

Copies the disk of a guest aside before a rebuild destroys it.

Returns Str|Undef, where the copy is, or undef.  Undef here, and nothing calls
this one: only a backend that answers true to C<rebuild_destroys_guest> has a
guest to copy aside.

    my $copy = $hv->clone_guest_disk('vm.example.test');

=cut

sub clone_guest_disk { return }

=head2 $hv->backup_volumes

Returns the names of the disks that C<clone_guest_disk> left behind.  An empty
list here, for the same reason.  Callers ask for this list and do not match
names themselves, so the name of a copy stays the business of the backend.

    my @copies = $hv->backup_volumes;

=cut

sub backup_volumes { return () }

=head2 $address = $hv->set_reverse_dns($domain, $name)

=over 4

=item domain - Str - the name of the guest

=item name - Str - the name that the address is to answer to

=back

Points the reverse DNS of the public address of the guest of C<$domain> at
C<$name>, and returns that address.  A receiver of mail rejects a client whose
address does not answer to the name that the client announces.  Only the holder
of the address can set its reverse record.

Returns nothing here, which means that this hypervisor offers no way.
F<bin/provision> then tells the operator to set it by hand.  A backend that
offers one overrides this, and dies when its hypervisor refuses.

    my $address = $hv->set_reverse_dns( 'vm.example.test', 'mail.example.test' );

=cut

sub set_reverse_dns { return }

=head1 PLACEMENT

Whether one more guest fits, and which hypervisor it fits on best.

The numbers come from the C<capacity> of a backend.  The judgment is here, so
the same rules place guests on every backend.

=head2 reserve_memory, reserve_cpus, reserve_disk, max_guests, cpu_overcommit

The limits from F<hypervisors.conf>.  C<reserve_memory> is the MB to keep for
the host, and C<reserve_cpus> is the CPUs to keep for the host.  C<reserve_disk>
is the bytes to keep free in the pool.  C<max_guests> caps the domain count, and
0 means no cap.  C<cpu_overcommit> is the acceptable number of vCPUs for each
physical CPU.  When the block names a C<partition>, C<max_guests> counts the
domains of that partition, and C<cpu_overcommit> applies to the CPUs of its
quota as well as to the host.  A partition can also have a budget of memory,
C<max_memory> in L<Trog::HV::Libvirt>.  See L<Trog::HV::Libvirt/capacity>.  The
defaults are 2048MB, 1 CPU, 10GB, no cap, and 4.

Returns Num, each, the limit or its default.

    my $memory = $hv->reserve_memory;
    my $cpus   = $hv->reserve_cpus;
    my $disk   = $hv->reserve_disk;
    my $cap    = $hv->max_guests;
    my $ratio  = $hv->cpu_overcommit;

=cut

sub reserve_memory ($self) { return $self->{reserve_memory} // 2048 }
sub reserve_cpus   ($self) { return $self->{reserve_cpus}   // 1 }
sub reserve_disk   ($self) { return $self->{reserve_disk}   // 10 * $Provisioner::Vars::GB }
sub max_guests     ($self) { return $self->{max_guests}     // 0 }
sub cpu_overcommit ($self) { return $self->{cpu_overcommit} // 4 }

=head2 capacity(%needs)

=over 4

=item needs - HashRef - what the guest asks for: C<memory_mb>, C<cpus> and
C<disk_bytes>

=back

Returns HashRef, what the hypervisor has, and what it already promised.  The
backend provides it, and here it dies, because the backend does not implement
it.  L</WHAT A BACKEND HAS TO PROVIDE> lists the keys of the hash.

C<%needs> is what the guest asks for, as L</shortfalls(%needs)> takes it.  A
machine has what it has whatever the guest wants, and ignores it.  A hypervisor
that sells a guest a size answers for the size this guest names in its
C<size_key>.

    my $have = $hv->capacity( memory_mb => 2048, cpus => 2, disk_bytes => $bytes );

=cut

sub capacity ( $self, @ ) { return abstract( $self, 'capacity' ) }

=head2 size_key

The C<_global> key that says what a guest is on this kind of hypervisor.  Undef
here, which is what a hypervisor that sizes a guest from its C<memory>, C<cpus>
and C<size> answers.  A hypervisor that sells sizes by name returns its key,
and a guest whose C<_global> does not name one is not built there: see
L</shortfalls(%needs)>.

Returns Str|Undef, the key, or undef.

    my $key = $hv->size_key;

=cut

sub size_key { return undef }

=head2 monthly_cost(%needs)

=over 4

=item needs - HashRef - C<memory_mb>, C<cpus> and C<disk_bytes>

=back

Returns Num, what a guest that wants C<memory_mb>, C<cpus> and C<disk_bytes> would
cost a month here, as a number in the currency the backend bills in.
L<Trog::Hypervisors/place($domain, %needs)> chooses the cheapest hypervisor that
fits before the roomiest one.

0 here: a machine that we own costs the same whether it runs one more guest or
not.  A backend that bills for each guest overrides it.  It dies when it cannot
find the price, and placement then reports it as unreachable, because a guess at
a price is the one answer that spends money.

    my $cost = $hv->monthly_cost( memory_mb => 2048, cpus => 2, disk_bytes => $bytes );

=cut

sub monthly_cost { return 0 }

=head2 cheapest_for(%needs)

=over 4

=item needs - HashRef - C<memory_mb>, C<cpus> and C<disk_bytes>

=back

What this hypervisor would sell to hold a guest that wants C<memory_mb>,
C<cpus> and C<disk_bytes>: a hashref of C<key>, the C<size_key> to write in the
guest's C<_global>, C<value>, the size to write there, and C<monthly_cost>,
what that would cost a month.  Undef when it has nothing that would hold the
guest, or nothing it may sell inside its budget.

Undef here.  A machine sells nothing: it has the room it has, which
L</shortfalls(%needs)> already answered for.  L<Trog::Hypervisors/select_for>
asks the ones that do when no machine has room, so an operator is offered
something rather than only told no.

Returns HashRef|Undef, the offer, or undef.

    my $offer = $hv->cheapest_for( memory_mb => 2048, cpus => 2, disk_bytes => $bytes );

=cut

sub cheapest_for { return undef }

=head2 shortfalls(%needs)

=over 4

=item needs - HashRef - C<memory_mb>, C<cpus> and C<disk_bytes>

=back

Returns every reason why this hypervisor cannot take a guest that wants
C<memory_mb>, C<cpus> and C<disk_bytes>, as a list of Str.  Each reason is text
that a person can act on.  An empty list means that the guest fits.  Dies as
the backend's C<capacity> does.

    my @reasons = $hv->shortfalls( memory_mb => 2048, cpus => 2, disk_bytes => $bytes );

=cut

# Whole gigabytes in a count of bytes, for a reason a person reads.
my sub gb ($bytes) { return int( ( $bytes // 0 ) / $Provisioner::Vars::GB ) }

sub shortfalls {
    my ( $self, %needs ) = @_;

    my $have = $self->capacity(%needs);
    my @reasons;

    # A partition has room of its own, and the host that it is on must have
    # room as well.  Its memory is its own only when it has a budget, and then
    # host has the memory of the whole hypervisor.  See capacity in
    # Trog::HV::Libvirt.
    my $host     = $have->{host};
    my $budgeted = $host && defined $host->{memory_free};
    push @reasons, sprintf(
        'needs %dMB of memory, %dMB free in the partition %s (%dMB for it, %dMB committed there)',
        $needs{memory_mb}, @{$have}{qw(memory_free partition memory_mb memory_committed)}
    ) if $budgeted && ( $needs{memory_mb} // 0 ) > $have->{memory_free};

    # An undefined free is no limit rather than no room.  A quota can be
    # unlimited, and a hypervisor says so by leaving the number undef, because
    # the -1 a cloud reports for it is not an amount to do arithmetic on.
    my $memory = $budgeted ? $host : $have;
    push @reasons, sprintf(
        'needs %dMB of memory, %dMB free%s (%dMB physical, %dMB committed, %dMB reserved)',
        $needs{memory_mb},                          $memory->{memory_free}, ( $host ? ' on the host' : q{} ),
        @{$memory}{qw(memory_mb memory_committed)}, $self->reserve_memory
    ) if defined $memory->{memory_free} && ( $needs{memory_mb} // 0 ) > $memory->{memory_free};

    push @reasons, sprintf(
        'needs %d vCPUs, %d free in the partition %s (%s CPUs for it x%d overcommit, %d committed there)',
        $needs{cpus},  @{$have}{qw(cpus_free partition)},
        $have->{cpus}, $self->cpu_overcommit, $have->{cpus_committed}
    ) if $host && defined $have->{cpus_free} && ( $needs{cpus} // 0 ) > $have->{cpus_free};

    my $whole = $host // $have;
    push @reasons, sprintf(
        'needs %d vCPUs, %d free%s (%d CPUs x%d overcommit, %d committed, %d reserved)',
        $needs{cpus},   $whole->{cpus_free}, ( $host ? ' on the host' : q{} ),
        $whole->{cpus}, $self->cpu_overcommit, $whole->{cpus_committed}, $self->reserve_cpus
    ) if defined $whole->{cpus_free} && ( $needs{cpus} // 0 ) > $whole->{cpus_free};

    push @reasons, sprintf(
        'needs %dGB of disk, %dGB free in the pool after a %dGB reserve',
        gb( $needs{disk_bytes} ), gb( $have->{disk_free} ), gb( $self->reserve_disk )
    ) if defined $have->{disk_free} && ( $needs{disk_bytes} // 0 ) > $have->{disk_free};

    push @reasons, sprintf( 'already has %d guests%s, and max_guests is %d', $have->{guests}, ( $host ? " in the partition $have->{partition}" : q{} ), $self->max_guests )
      if $self->max_guests && $have->{guests} >= $self->max_guests;

    return @reasons;
}

=head2 headroom(%needs)

=over 4

=item needs - HashRef - C<memory_mb>, C<cpus> and C<disk_bytes>

=back

Returns Num, how much room this hypervisor has left after it takes the guest,
from 0 (exactly full) to 1 (empty).  The value comes from the tightest of the
three resources.  Placement by the tightest resource stops one hypervisor from
filling its disk while the fleet still has plenty of RAM.  Dies as the
backend's C<capacity> does.

    my $room = $hv->headroom( memory_mb => 2048, cpus => 2, disk_bytes => $bytes );

=cut

# The share of $total that is still free once $wanted is taken out of $free.
my sub fraction ( $free, $total, $wanted ) {

    # No limit is as empty as it gets, and nothing to divide by is as full.
    return 1 unless defined $free && defined $total;
    return 0 if !$total;

    my $fraction = ( $free - ( $wanted // 0 ) ) / $total;
    return $fraction < 0 ? 0 : $fraction;
}

sub headroom {
    my ( $self, %needs ) = @_;

    my $have = $self->capacity(%needs);
    my @fractions;

    push @fractions, fraction( @{$have}{qw(memory_free memory_mb)},      $needs{memory_mb} );
    push @fractions, fraction( @{$have}{qw(cpus_free cpus_allocatable)}, $needs{cpus} );
    push @fractions, fraction( $have->{disk_free},                       defined $have->{disk_free} ? $have->{disk_free} + ( $needs{disk_bytes} // 0 ) : undef, $needs{disk_bytes} );

    # A partition is as roomy as the host that it is on, at most.
    push @fractions, fraction( @{ $have->{host} }{qw(cpus_free cpus_allocatable)}, $needs{cpus} )      if $have->{host};
    push @fractions, fraction( @{ $have->{host} }{qw(memory_free memory_mb)},      $needs{memory_mb} ) if $have->{host} && defined $have->{host}{memory_free};

    my ($tightest) = sort { $a <=> $b } @fractions;
    return $tightest;
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
them, as a list of Str.  Each name is a method on the backend.  A failed check
means that a guest cannot be built.  Here it dies, because the backend does not
implement it.

    my @checks = $hv->preflight_checks();

=head2 @names = $hv->preflight_notes()

The same, for things that are good to have but not required.

Returns the names of the notes, as a list of Str.  Here it dies, because the
backend does not implement it.

    my @notes = $hv->preflight_notes();

=head2 @names = $hv->preflight_block_checks()

The few of those that F<bin/preflight> asks of every I<other> block in
F<hypervisors.conf>, rather than only of the hypervisor a run would build on.

A run builds on one hypervisor, so the full list above is asked of one.  But a
block can be wrong in ways that have nothing to do with reaching its hypervisor
-- a cloud that nobody gave an address to fetch from is the one that keeps
happening -- and a fault like that is found when a guest is placed there, which
is a run that has already started.

So a check belongs in this list when it needs nothing but this machine and the
block itself.  A check that opens a connection, authenticates, or reads a
credential does not: asking every block those would contact every cloud in the
fleet, and open the secret store, to preflight a run against one machine.

Returns the names, as a list of Str: C<check_client> and
C<check_transfer_route> here.

    my @checks = $hv->preflight_block_checks();

=cut

sub preflight_checks ( $self, @ ) { return abstract( $self, 'preflight_checks' ) }
sub preflight_notes  ( $self, @ ) { return abstract( $self, 'preflight_notes' ) }

sub preflight_block_checks { return qw{check_client check_transfer_route} }

=head2 $result = $hv->verdict($ok, $what, $fix)

=over 4

=item ok - Bool - true when nothing is wrong

=item what - Str - what was found

=item fix - Str - what to do about it, or empty

=back

Returns HashRef, the answer of one check, in the form that C<bin/preflight> prints:
C<{ ok =E<gt> $ok, what =E<gt> $what, fix =E<gt> $fix }>.  C<$ok> is true when
nothing is wrong.  C<$what> says what was found, and C<$fix> says what to do
about it, or is empty when there is nothing to do.

The checks of this class and of every backend answer through it, so that the
form is written down in one place.

    return $self->verdict( 1, 'rsync on both ends', q{} );

=cut

sub verdict {
    my ( $self, $ok, $what, $fix ) = @_;
    return { ok => $ok, what => $what, fix => $fix };
}

=head2 $result = $hv->check_client()

Checks that the API client of this backend is installed, which every other
check of a hypervisor needs and none of them says.  This class answers it for
every backend, and each backend lists it first, because a missing client makes
the checks after it fail for a reason that is not theirs.

A backend class answers it as well as a hypervisor, which is how F<bin/preflight>
judges a block it has not built.

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_client();

=cut

sub check_client {
    my ($self) = @_;

    my ($module) = $self->client_module;
    return $self->verdict( 0, "$module will not load here", $@ ) unless eval { $self->require_client; 1 };

    return $self->verdict( 1, "$module " . $module->VERSION . ' is installed', q{} );
}

=head2 $hv->check_reachable(), $hv->check_transfer_ip()

This class declares both, and the backend answers them.  Both questions apply to
either kind, but the answers have nothing in common.

To reach a machine is an ssh login.  To reach a cloud is a credential that
authenticates, and a catalog with compute, image and network in it.  To find the
address that a guest fetches from, libvirt asks the routing table about a NAT
bridge.  A cloud reads it out of the configuration, because it has nothing to
ask until the guest exists.

Returns HashRef, the answer of C<verdict>, each.  Here each dies, because the
backend does not implement it.

    my $reached = $hv->check_reachable();
    my $named   = $hv->check_transfer_ip();

=cut

sub check_reachable   ( $self, @ ) { return abstract( $self, 'check_reachable' ) }
sub check_transfer_ip ( $self, @ ) { return abstract( $self, 'check_transfer_ip' ) }

=head2 $network = $hv->guest_network_of($address)

=over 4

=item address - Str - an address of this machine

=back

Returns Str|Undef, the network, as a CIDR, of a guest here whose own network holds
C<$address>, or undef when none does.

A backend that addresses its own guests may still put them on a private network
this machine is also on, and then they reach us across it with no forward.
Only the backend can say what networks its guests are on.  Undef here, which is
the answer for a service on the internet.

    my $network = $hv->guest_network_of('192.0.2.10');

=cut

sub guest_network_of { return }

=head2 $result = $hv->check_transfer_route()

Works out where a guest built here fetches its payload from, and says whether
that address can be one this machine answers on.

A guest on a machine of ours reaches us across a network we share, and the
routing table settles it when the configuration is generated.  A guest that the
hypervisor addresses itself -- one on a cloud -- reaches us from outside, at the
C<transfer_ip> and C<transfer_port> of its block, or of C<_global>.  Three
things can be wrong with that, and each has its own answer:

=over 4

=item * The address is a private one.  Nothing on the internet routes to it, so
a guest there can never fetch -- unless the address is ours and on the network
of a guest here, which C<guest_network_of> answers for, and then the guest
reaches it directly.

=item * The address is not one of ours.  Then something in front of us answers
for it, and it has to forward C<transfer_port> to the sshd of this machine.
This says so, and says whether anything answered when it tried, which a gateway
that does not answer its own public address from inside will get wrong.

=item * Nothing names an address at all, which the check_transfer_ip of each
backend covers as well.

=back

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_transfer_route();

=cut

sub check_transfer_route {
    my ($self) = @_;

    my $here = Trog::Local->new();

    # Unvalidated, so that a _global that check_config refuses still says
    # where guests fetch from.
    my $global = eval { Provisioner::Cookbook->base_global() } // {};
    my $ip     = $self->configured_transfer_ip                 // $global->{transfer_ip};
    my $port   = $self->configured_transfer_port               // $global->{transfer_port} // $here->sshd_port;

    return $self->verdict( 1, 'Guests here reach us across our own network, which the routing table settles', q{} )
      unless $self->manages_addresses;

    return $self->verdict( 0, 'Nothing says where guests on ' . $self->describe . ' fetch from', <<"FIX" ) unless $ip;
A guest there is not on a network of ours, so the routing table cannot answer
for it.  Name the address it reaches us at, and the port, in the block of this
hypervisor in hypervisors.conf:

    transfer_ip   = 192.0.2.10
    transfer_port = 2222
FIX

    # The blocks nothing on the internet routes to.
    my $private = any { $ip =~ $_ } qr/\A(?:10|127)[.]/, qr/\A(?:169[.]254|192[.]168)[.]/, qr/\A172[.](?:1[6-9]|2\d|3[01])[.]/;

    my $shared = $private && $here->holds_address($ip) ? $self->guest_network_of($ip) : undef;
    return $self->verdict( 1, "Guests here fetch from $ip:$port, which is an address of this machine on $shared, a network of theirs", q{} ) if $shared;

    return $self->verdict( 0, "Guests on " . $self->describe . " are told to fetch from $ip, which is a private address", <<"FIX" ) if $private;
Nothing outside our network routes to $ip, and no guest there is on a network
with it, so a guest there can never fetch its payload.  Where this machine is
on the guests' own network, name its address on that network instead.
Otherwise put the address that reaches this machine from the internet in the
block of this hypervisor in hypervisors.conf, with the port forwarded to the
sshd here:

    transfer_ip   = <the address of your gateway>
    transfer_port = <the port it forwards to this machine>
FIX

    return $self->verdict( 1, "Guests here fetch from $ip:$port, which is an address of this machine", q{} )
      if $here->holds_address($ip);

    my $answered = $here->answers_on( $ip, $port );
    return $self->verdict( 1, "Guests here fetch from $ip:$port, which answers, so something forwards it here", q{} ) if $answered;

    return $self->verdict( 0, "Guests here fetch from $ip:$port, which is not ours and did not answer", <<"FIX" );
$ip is not an address of this machine, so something in front of us answers for
it, and it has to forward $port to the sshd here.  Nothing answered when this
tried, which means one of two things:

    * the forward is not there, and a guest on @{[ $self->describe ]} cannot fetch;
    * the forward is there, and the gateway does not answer its own public
      address from inside the network, which many do not.

Try it from outside -- from a guest you already have there, or any host on the
internet:

    nc -vz $ip $port
FIX
}

=head2 $result = $hv->check_rsync()

Checks that rsync is on this machine and, for a remote hypervisor, on the
hypervisor too.  The data directory of a domain goes up to the hypervisor over
rsync, and comes off the guest that is replaced over rsync.  Nothing else in
this toolkit must exist on both the machine that drives a run and the machine
that it drives.

It does not check guests.  Every guest that this tool builds installs rsync
among its base packages, and a guest that is not built yet has nothing to
salvage.

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_rsync();

=cut

sub check_rsync {
    my ($self) = @_;

    my @missing;
    push( @missing, 'this machine' ) unless File::Which::which('rsync');
    push( @missing, $self->describe ) if !$self->is_local && $self->run_cmd( 'sh', '-c', 'command -v rsync >/dev/null 2>&1' ) != 0;

    return $self->verdict( 1, 'rsync on both ends', q{} ) unless @missing;

    my $where = join( ' and ', @missing );
    return $self->verdict( 0, "No rsync on $where", <<"FIX" );
A domain's data directory is shipped to the hypervisor and salvaged off the old
guest with it, and both of those compare before they transfer -- which is what
keeps a re-provision from moving twenty gigabytes of video it already has.

    sudo apt install rsync

on $where.
FIX
}

=head2 $result = $hv->check_sandbox()

Checks that the sandbox program that the fetches of a guest run in is
installed on this machine, owned by root, that this account can write the
directory of guest keys, and that bubblewrap can make the sandbox.  Without
them, C<bin/provision> refuses to authorize the key of a guest, because the key
would fetch nothing.  See L<Trog::Local/THE KEYS OF
GUESTS>.  It asks only this machine, because the guest fetches from here and
not from the hypervisor.

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_sandbox();

=cut

sub check_sandbox {
    my ($self) = @_;

    my $local = Trog::Local->new();
    if ( my $missing = $local->sandbox_program_error // $local->guest_keys_error ) {
        my $keys = eval { $local->guest_keys() } // $Trog::Utils::GUEST_KEYS;
        my $env  = $keys eq $Trog::Utils::GUEST_KEYS ? q{} : "env TROG_GUEST_KEYS=$keys ";
        return $self->verdict( 0, "No sandbox for the fetches of a guest on this machine: $missing", <<"FIX" );
The key of each guest runs only the sandbox program, which root must own, so
that the account that writes a domain directory cannot change what the key
runs.  This account lets the key in by writing it into the directory of guest
keys.  As root, with the account that guests connect as:

    sudo ${env}scripts/setup_transfer_user USER

The trogrunner recipe does the same on a guest that it builds.
FIX
    }

    my $why = $local->sandbox_error;
    return $self->verdict( 1, 'bubblewrap can confine the fetches of a guest', q{} ) unless $why;

    return $self->verdict( 0, "No sandbox for the fetches of a guest on this machine: $why", <<'FIX' );
Each guest fetches its payload from this machine over ssh, and its key runs
only rsync, inside a bubblewrap sandbox that holds what the guest may fetch.
Install bubblewrap:

    sudo apt install bubblewrap

If it is installed and still refused, the system does not let it make a user
namespace.  On Ubuntu 24.04 and later, AppArmor allows that only to a program
with a profile, and the bubblewrap package ships none.  The trogrunner recipe
installs one in /etc/apparmor.d/bwrap.  On a machine set up by hand, copy
templates/files/trogrunner.bwrap.apparmor.tt of this checkout there, and load
it with apparmor_parser -r.
Elsewhere, see the user.max_user_namespaces sysctl.
FIX
}

=head2 $result = $hv->check_gpg()

Checks that this machine has a gpg that L<Provisioner::Packager::Deb> can read
a signing key with.  C<bin/new_config> reads the fingerprint of the key of each
apt archive that names one, such as those that tCMS declares, and stops
without it.  It asks only this machine, because C<new_config> runs here.

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_gpg();

=cut

sub check_gpg {
    my ($self) = @_;

    my $why = Provisioner::Packager::Deb->gpg_error;
    return $self->verdict( 1, 'gpg can read the fingerprint of a signing key', q{} ) unless defined $why;

    return $self->verdict( 0, "No gpg on this machine that can read a signing key: $why", <<'FIX' );
bin/new_config reads the fingerprint of the signing key of each third-party apt
archive with gpg --show-keys, and refuses an archive whose key it cannot read.
Install GnuPG 2.2.8 or later:

    sudo apt install gpg
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

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_fetch_sources();

=cut

sub check_fetch_sources {
    my ($self) = @_;

    my $conf = eval { Provisioner::Cookbook->configuration() } // {};
    my %wanted;

    foreach my $domain ( Provisioner::Cookbook->domains($conf) ) {
        my $recipes = eval { Provisioner::Cookbook->domain_config( $domain, $conf ) } // {};

        foreach my $name ( sort keys %$recipes ) {
            my $class = eval { Provisioner::Cookbook->load($name) } or next;
            next unless $class->can('fetch_sources');

            my $opts = $recipes->{$name} // {};
            next unless ref $opts eq 'HASH';

            my %paths = eval { $class->fetch_sources(%$opts) };
            foreach my $path ( values %paths ) {
                next unless $path;
                $wanted{$path}{$name} = 1;
            }
        }
    }

    return $self->verdict( 1, 'No recipe fetches a directory of yours', q{} ) unless %wanted;

    my @missing = grep { !-d } sort keys %wanted;
    return $self->verdict( 1, scalar( keys %wanted ) . ' fetched ' . ( keys %wanted == 1 ? 'directory is' : 'directories are' ) . ' here', q{} ) unless @missing;

    my $detail = join( q{}, map { "    $_ (" . join( ', ', sort keys %{ $wanted{$_} } ) . ")\n" } @missing );
    return $self->verdict( 0, scalar(@missing) . ' fetched ' . ( @missing == 1 ? 'directory is' : 'directories are' ) . ' not on this machine', <<"FIX" );
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
F<recipes.yaml> that says what its guests are built with.  It validates the
C<_global> of C<_base> and of each domain, as F<bin/new_config> does.  See
L<Provisioner::Cookbook/globals>.

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_config();

=cut

sub check_config {
    my ($self) = @_;

    my $dir = Trog::Config->dir;

    my @missing = grep { !-r "$dir/$_" } qw{recipes.yaml admin_authorized_keys};    ## no critic (ValuesAndExpressions::ProhibitFiletest_rwxRWX) -- the only question is whether it can be read, and what reads it opens it itself

    # An empty key file passes a check for existence and then stops
    # bin/new_config, which is the failure that this check prevents.
    push( @missing, 'admin_authorized_keys' )
      if !@missing && !-s "$dir/admin_authorized_keys";

    if ( !@missing ) {
        my $said = eval {
            my $conf = Provisioner::Cookbook->configuration();
            Provisioner::Cookbook->base_globals($conf);
            for my $item ( ( Provisioner::Cookbook->domains($conf) ) ) { Provisioner::Cookbook->globals( $item, $conf ); }
            1;
        };
        return $self->verdict( 1, "Configuration to copy from: $dir", q{} ) if $said;

        # Ten minutes into a build otherwise: bin/new_config reads these for
        # the first domain it generates, and every recipe that owns a file on
        # the guest wants one of them.
        return $self->verdict( 0, 'The settings every guest is built with are missing or wrong', "$@" . <<"FIX" );
An installation that still has an ipmap.cfg in $dir has them
in that file, and moves them across with:

    bin/ipmap_to_globals --dryrun
    bin/ipmap_to_globals

docs/CONFIGURATION.md says what each one is.
FIX
    }

    return $self->verdict( 0, "Missing or empty in $dir: " . join( ', ', @missing ), <<"FIX" );
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

=head2 $result = $hv->note_stale_image()

Whether the image that guests are built on is still the current one from the
distribution.  It is a note and not a check.  A pin one release behind can be a
deliberate decision, and a mirror that does not answer is no reason to refuse a
build.

Returns HashRef, with C<ok>, and C<what> and C<fix> when it is not ok.

    my $note = $hv->note_stale_image();

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

Returns HashRef, with C<ok>, and C<what> and C<fix> when it is not ok.

    my $note = $hv->note_apt_mirror();

=cut

sub note_apt_mirror {
    my $conf = eval { Provisioner::Cookbook->configuration() } // {};

    my @domains = Provisioner::Cookbook->domains($conf);
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

A secret is what the schema of its recipe marks C<x-secret>; see
L<Provisioner::Recipe/secrets_in>.  A block for a recipe that does not load is
skipped, because preflight has other checks for that.  Also, any value that is
a private key is a secret wherever it is, so a key pasted into a field that no
schema marks is found too.

Returns HashRef, with C<ok>, and C<what> and C<fix> when it is not ok.

    my $note = $hv->note_plaintext_secrets();

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
        next if ref $conf ne 'HASH';

        my %found;
        foreach my $top ( sort keys %$conf ) {
            my $recipes = $conf->{$top};
            next if ref $recipes ne 'HASH';
            foreach my $name ( sort grep { !m/\A_/ } keys %$recipes ) {
                my $class = eval { Provisioner::Cookbook->load($name) } or next;

                # A reference is not a secret.  Neither is a placeholder from
                # bin/new_guest, because new_config refuses to build from one.
                $found{"$top.$name.$_->[0]"} = 1
                  for grep { local ($_) = $_; $_->[1] !~ m/\Asecret:/ && $_->[1] ne Provisioner::Cookbook->PLACEHOLDER } $class->secrets_in( $recipes->{$name} );
            }
        }

        $found{ $_->[0] } = 1 for grep {
            my $value = ${ $_->[1] };
            !ref $value && defined $value && $value =~ m/-----BEGIN[ ][[:upper:] ]*PRIVATE[ ]KEY-----/
        } Trog::Utils::slots_in( \$conf, q{} );

        push( @found, map { { file => $file, at => $_ } } sort keys %found );
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

=head1 SEE ALSO

L<Trog::HV::Libvirt>, the backend that builds guests with libvirt.

L<Trog::HV::OpenStack>, the one that asks a cloud.

L<Trog::HV::Linode>, the one that buys a Linode for each guest.

L<Trog::HV::SolusVM>, the one that asks a SolusVM management node.

L<Trog::HV::Cloud>, what every backend that builds by API has in common.

L<Trog::Machine>, which this is one of.

L<Trog::Hypervisors>, which chooses between several of these.

=cut

1;
