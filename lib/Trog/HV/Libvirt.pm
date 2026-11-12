package Trog::HV::Libvirt;

#ABSTRACT: the libvirt backend: domains, storage pools and the facts of a qemu host.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::HV';

use Digest::SHA();
use URI();
use URI::Split();

use List::Util();
use Time::HiRes qw{sleep time};
use Trog::Local();
use Trog::Utils();
use File::Basename();
use File::Slurper();
use List::Util();
use Cpanel::JSON::XS();
use Net::CIDR();
use Net::IP();
use Provisioner::Cookbook();
use Provisioner::Vars();
use Trog::HV::Libvirt::BridgeHelper();
use Trog::Patterns();

# The snapshot of a new, empty overlay, which a rebuild that keeps the disk
# reverts to.  create_disk takes it and clear_guest reverts to it.  It is
# declared at the top because a file-scoped my is not visible above its line.
my $PRISTINE_SNAPSHOT = 'trog-pristine';

# The suffix that clone_guest_disk gives a copy, and that backup_volumes finds.
my $BACKUP_SUFFIX = '.bak-qcow2';

# Where distributions put the libvirt lease helper, which release_dhcp_lease
# runs as root.  At the top for the reason $PRISTINE_SNAPSHOT is.
my @LEASE_HELPERS = qw{/usr/lib/libvirt/libvirt_leaseshelper /usr/libexec/libvirt_leaseshelper};

=head1 NAME

Trog::HV::Libvirt - the libvirt backend: domains, storage pools and the facts of
a qemu host

=head1 SYNOPSIS

    # Not built directly.  Trog::HV chooses a backend and hands one back.
    my $hv = Trog::HV->new(uri => 'qemu+ssh://root@hv1.example.net/system');

    $hv->annihilate_domain('vm.example.test');
    print $hv->pool_path, "\n";

=head1 DESCRIPTION

This backend reaches a hypervisor by a libvirt connection URI.  All libvirt
calls go through L<Sys::Virt>, as L</LIBVIRT> describes.

L<Trog::HV> holds what is not specific to libvirt: the singleton, the directory
for each domain, and the placement arithmetic.

The code above this backend depends on two facts.  The hypervisor is a machine
that we can get a shell on.  Its storage is a libvirt pool on the filesystem of
that machine.  A backend without both of these cannot replace this one.

=head1 CLASS METHODS

=cut

our $DEFAULT_URI = 'qemu:///system';

# Where a console capture is written on the hypervisor, and the pause a restart
# leaves between stopping a domain and starting it again.
our $CONSOLE_LOG_DIR = '/tmp';
my $RESTART_SETTLE = 2;

# How long refresh_pool waits out the jobs of another provision on the pool, and
# how often it asks again.
our $POOL_BUSY_WAIT     = 600;
our $POOL_BUSY_INTERVAL = 2;

# The transports that also give us a shell on the hypervisor.
my %SSH_TRANSPORT = map { $_ => 1 } qw{ssh libssh libssh2};

=head2 marker

Returns C<uri>, the option that makes a block a libvirt one, from
C<libvirt_uri>.  A block with no backend's marker is one too, because this
backend can talk to the machine it runs on.

=head2 client_module

Returns L<Sys::Virt>, which L<Trog::HV/$module = $hv-E<gt>require_client> loads
when the connection is first opened.  It is not installed on an installation
whose fleet is all clouds, and L<< /$result = $hv->check_sys_virt_in_step() >> is where a
fleet with a libvirt hypervisor finds out that it has the wrong one.

=head2 config_keys

Returns the pairs of constructor option and F<hypervisors.conf> key that this
backend reads.  A block with C<libvirt_uri> in it is a block for this backend.

=cut

sub marker        { return 'uri' }
sub client_module { return 'Sys::Virt' }

sub config_keys {
    return (
        uri => 'libvirt_uri',
        map { $_ => $_ } qw{pool_path pool_name domain_dir dhcp_nics static_nics partition max_memory},
    );
}

=head2 build(%given)

Returns a new object for this backend.  L<Trog::HV/candidate> calls it after it
selects this backend for the options.

C<uri> defaults to C<qemu:///system>.  See L</explicit> for what the default
changes.

Dies if the URI does not parse.  Also dies if the hypervisor is remote and the
transport gives no shell, because files and bridge detection need one.  Also
dies if it gets a L</max_memory> and no L</partition>, and if the adapters of
the block are not ones that a guest can have: see L</ADAPTERS>.

=cut

sub build {
    my ( $class, %given ) = @_;

    my $uri      = $given{uri};
    my $explicit = defined($uri) ? 1 : 0;
    $uri = $DEFAULT_URI unless $explicit;

    # A libvirt connection URI has the form
    # driver[+transport]://[user@][host][:port]/path.  URI does not know the
    # driver+transport scheme, so it returns a URI::_foreign with no authority
    # accessors.  So the URI is split, and its authority parsed again as ssh,
    # which gives user, bracketed IPv6 and port without a regex of our own.
    my ( $scheme, $authority, $path ) = URI::Split::uri_split($uri);
    my ( $driver, $transport ) = split( quotemeta('+'), $scheme // q{}, 2 );
    die "Could not parse libvirt connection URI '$uri'\n" unless $driver;

    my $server = $authority ? URI->new("ssh://$authority") : undef;

    my $self = bless {
        %given,
        uri       => $uri,
        explicit  => $explicit,
        driver    => $driver,
        transport => $transport,
        user      => $server                      ? $server->user : undef,
        host      => ( $server && $server->host ) ? $server->host : undef,
        port      => $server                      ? $server->port : undef,
        path      => $path,
    }, $class;

    # A session daemon puts every domain in the user slice of its account, and
    # refuses a partition.  Refused here, not when the first domain is defined.
    die "The hypervisor at $uri is a session of libvirt, whose guests run in the user slice of its account, so it cannot have a partition.\n"
      if $self->is_session && defined $given{partition};

    # reserve_memory already caps the memory of the whole host.  A budget with
    # no partition would be a second name for that, and the two could disagree.
    # The guests of a session are a share of their own, as a partition is.
    die "max_memory is a budget for the guests of a partition, and the hypervisor at $uri names no partition.\n" . "To cap the memory of every guest on it, raise reserve_memory instead.\n"
      if $given{max_memory} && !defined $given{partition} && !$self->is_session;

    # Fail now, not three minutes into a provision.
    die "The hypervisor at $uri is remote, but its transport gives us no shell.\n" . "Use an ssh transport instead, e.g. qemu+ssh://root\@" . ( $self->{host} // 'hypervisor' ) . "/system, so we can reach its filesystem.\n"
      if !$self->is_local && !defined $self->ssh_host;

    # The adapters of the block, and the pool and the gateway of each static
    # one, are checked here, because a list of bridges cannot be probed for
    # later.  See ADAPTERS.
    my $who    = $given{name} // $uri;
    my @dhcp   = $self->setting_list('dhcp_nics');
    my @static = $self->setting_list('static_nics');

    my ($bad) = grep { !m/$Trog::Patterns::LINK_NAME/ } @dhcp, @static;
    die "The adapters of $who name '$bad', which is not the name of a bridge\n" if defined $bad;

    my %seen;
    my ($twice) = grep { $seen{$_}++ } @dhcp, @static;
    die "The adapters of $who name $twice twice, and a guest has one adapter on each bridge\n" if defined $twice;

    my %static = map { $_ => 1 } @static;
    foreach my $key ( sort grep { m/$Trog::HV::NIC_KEY/ } keys %$self ) {
        my ($nic) = $key =~ m/$Trog::HV::NIC_KEY/;
        die "$key for $who is for the bridge $nic, which static_nics does not name.  A pool and a gateway are for a static adapter, and a guest has no adapter outside dhcp_nics and static_nics.\n"
          unless $static{$nic};
    }

    die "$static[0], the first of static_nics for $who, gives the guest its address and its default route, so name its gateway: gateway_$static[0]\n"
      if @static && !defined $self->nic_gateway( $static[0] );

    foreach my $nic (@static) {
        my $pool = $self->nic_pool($nic);
        die "$nic in static_nics for $who has no pool.  Name ip_pool_$nic, or ip_addresses_$nic, with the addresses that its adapter takes.\n" unless %$pool;

        # An address may carry its own prefix, and each other one gets the
        # prefix of the network of the bridge, inside which it has to be.
        my @bare = @{ $pool->{cidr} // [] };
        foreach my $item ( @{ $pool->{addresses} // [] } ) {
            my ( $address, $prefix ) = split m{/}, $item, 2;
            my $ip = Net::IP->new($address);
            die "The pool of $nic for $who names '$item', which is not an IPv4 address, with or without the length of its prefix\n"
              if !$ip || $ip->version != 4 || $ip->size != 1 || defined $prefix && !Trog::HV::is_prefix_length($prefix);
            push @bare, $address unless defined $prefix;
        }
        foreach my $item (@bare) {
            my $ip = Net::IP->new($item);
            die "The pool of $nic for $who names '$item', which is not an IPv4 address or block\n" unless $ip && $ip->version == 4;
        }
        $self->nic_gateway($nic);
        next unless @bare;

        my $network = Net::IP->new( $self->nic_network($nic) );
        my @outside = grep { my $how = Net::IP->new($_)->overlaps($network) // 0; $how != $Net::IP::IP_A_IN_B_OVERLAP && $how != $Net::IP::IP_IDENTICAL } @bare;
        die "The pool of $nic for $who has " . join( ', ', @outside ) . ' outside ' . $self->nic_network($nic) . ", the network of $nic, so a guest with one of those addresses could not reach anything on it\n"
          if @outside;
    }

    return $self;
}

=head1 IDENTITY

=head2 uri

The libvirt connection URI.  The default is C<qemu:///system>.

=head2 explicit

True when the caller gave a URI, false when the URI is the default.  When it is
false, libvirt selects its own default connection, as C<virsh> does with no
C<-c>.

=head2 is_local

True when the hypervisor is the machine that runs this code.

=cut

=head2 is_session

True when the URI names the session daemon of its user, C<qemu:///session> or
C<qemu+ssh://user@host/session>, and not the system daemon.

A session daemon runs as its user, and so does each qemu that it starts.  So a
domain there can open only the files that the user can open, and the user needs
no group that the system daemon trusts.  That is what makes a runner account
narrow.  See L</RUNNER ACCOUNTS>.  It changes four things here:

=over 4

=item * The NAT interface of a guest is a C<bridge> interface on
L</lease_nic>, through C<qemu-bridge-helper>, because a session cannot use
a network of the system daemon.  L<Trog::HV::Libvirt::BridgeHelper> has the
helper, and the ACL that says which bridges the account may join.

=item * The leases of the NAT network come from a read-only connection to the
system daemon.  See L</network_vmm>.

=item * qemu-img runs as the user, because the user owns the disks.

=item * L</capacity> counts the guests of the session as a share of their own,
in the user slice of the account.

=back

=head2 local_uri

The URI that names the same daemon on the hypervisor itself: the driver and the
path of L</uri>, with no transport, host, port or query, for example
C<qemu:///session>.  It is for a command that runs on the hypervisor, such as
C<virsh -c>.  Without C<-c>, C<virsh> as a user other than root asks the session
of that user, also when L</uri> names the system daemon.

The command runs as the login user of L</uri>.  So it reaches the daemon with
the access that L</vmm> has, and needs no sudo.

It is empty when L</uri> is not L</explicit>.  libvirt reads an empty URI as no
URI, and selects its default, as L</vmm> lets it.

=cut

sub explicit   ($self) { return $self->{explicit} }
sub uri        ($self) { return $self->setting('uri') }
sub is_session ($self) { return ( $self->{path} // q{} ) eq '/session' }
sub local_uri  ($self) { return $self->explicit ? "$self->{driver}://$self->{path}" : q{} }

sub is_local {
    my ($self) = @_;
    return !defined $self->{host};
}

=head2 ssh_host

The host to ssh to when a command must run on the hypervisor.  It comes from the
connection URI.  Undef when the hypervisor is local, or when the transport gives
no shell, which C<build> refuses.  L<Trog::Machine> has C<ssh_user>,
C<ssh_port> and C<ssh_target>.

=head2 describe

What to call the hypervisor in a message: "the hypervisor at" and the URI.

=cut

sub ssh_host {
    my ($self) = @_;
    return undef unless defined $self->{host};

    # A bare qemu://host/system uses the native remote transport of libvirt,
    # which also goes over ssh by default.
    return $self->{host} if !defined $self->{transport} || $SSH_TRANSPORT{ $self->{transport} };
    return undef;
}

sub describe ($self) { return 'the hypervisor at ' . $self->uri }

=head1 PATHS

=head2 pool_path

The directory where the storage pool keeps its volumes.  The configured
C<pool_path> wins.  If there is none, the method asks libvirt with
C<pool_target>, because this code deletes files from that path.  If libvirt has
no such pool, the result is F</opt/terraform/disks>, where existing hypervisors
keep their volumes.

=head2 pool_name

The name of the storage pool for the guests on this hypervisor.  The default is
C<tf_disks>, and F<hypervisors.conf> can change it.

libvirt finds a pool by its name.  If a pool of that name already exists, libvirt
ignores C<pool_path> and puts every volume where that pool points.  So to give
a hypervisor its own pool, set both keys.  A pool on a filesystem with a quota is
the only quota that applies to libvirt guests.

=head2 partition

The cgroup partition for the guests on this hypervisor, or undef for the libvirt
default of C</machine>.  It sets no limit.  It puts every guest built here in
one systemd slice, where an operator can limit CPU and I/O for all of them.

When it is set, L</capacity> counts the guests and the vCPUs of this partition
only, so that C<max_guests> and C<cpu_overcommit> are limits on it and not on
the whole hypervisor.

=head2 max_memory

The MB of memory that the guests of the L</partition> may hold together, or 0
for no budget, which is the default.  A guest counts with all of its memory,
running or not, as it does on the host.  This limits what a build may promise,
not what a guest uses.  The kernel enforces nothing here, because a
C<MemoryMax> on the slice kills a guest and does not refuse the next one.

L</build(%given)> refuses it without a partition, because C<reserve_memory> already
caps the memory of the whole host.

=head2 $unit = Trog::HV::Libvirt::partition_slice($partition)

The systemd unit of the slice that libvirt makes for C<$partition>: the path
without its first slash, with each other slash a dash, and C<.slice> after it.
So C</machine/runner> is F<machine-runner.slice>.

=head2 $cores = $hv->slice_cpu_quota($unit)

The C<CPUQuota> of the slice C<$unit> on this hypervisor, in cores: 4 for
C<400%>.  Undef when the slice has no quota, or when C<systemctl> does not
answer.  systemd answers for a slice that is not running yet, from its unit
file, so a runner that has no running guest still gets its quota.  Dies when
C<$unit> is not the name of a slice, because it goes into a shell command.

=cut

sub pool_name  ($self) { return $self->setting('pool_name') // 'tf_disks' }
sub partition  ($self) { return $self->setting('partition') }
sub max_memory ($self) { return $self->setting('max_memory') // 0 }

sub partition_slice ($partition) { return ( $partition =~ s{\A/}{}r =~ tr{/}{-}r ) . '.slice' }

=head2 $unit = $hv->session_slice()

The user slice of the account of a session URI, F<user-UID.slice>, where systemd
puts every process of that user, and so the qemu of each guest of the session.
Dies when the hypervisor does not say the uid of the user.  It asks once, and
remembers the answer.

=cut

sub session_slice ($self) {
    return $self->{session_slice} //= do {
        my $uid = $self->capture_cmd('id -u') // q{};
        chomp $uid;
        die 'Could not ask ' . $self->describe . " for the uid of its user\n" unless $uid =~ m/\A\d+\z/;
        "user-$uid.slice";
    };
}

# The units that systemd writes a time span in, in seconds.
my %SPAN_UNIT = ( us => 1e-6, ms => 1e-3, s => 1, min => 60 );

sub slice_cpu_quota ( $self, $unit ) {

    die "'$unit' is not the name of a slice\n" unless $unit =~ m{\A[\w.-]+[.]slice\z};

    # libvirt does not manage the slice of a partition, so systemd is asked.
    # CPUQuotaPerSecUSec is the CPU time that the slice gets in each second,
    # such as 4s for 400% or 500ms for 50%.  A long fraction is written as
    # 1.500000s, and a mix of units as 1s 500ms, so each part adds up.
    my $span = $self->capture_cmd("systemctl --no-pager show -p CPUQuotaPerSecUSec --value $unit") // q{};
    chomp $span;

    my $seconds = 0;
    while ( $span =~ m{(\d+(?:[.]\d+)?)(us|ms|s|min)\b}g ) {
        $seconds += $1 * $SPAN_UNIT{$2};
    }
    return $seconds > 0 ? $seconds : undef;
}

sub pool_path {
    my ($self) = @_;
    return $self->{pool_path} if defined $self->{pool_path};

    return $self->{_pool_path} //= ( $self->pool_target( $self->pool_name ) // '/opt/terraform/disks' );
}

=head2 pool_target($name)

The target directory that libvirt has for the pool C<$name>, or undef when
there is no such pool.  C<$name> defaults to L</pool_name>.

=cut

sub pool_target {
    my ( $self, $name ) = @_;
    $name //= $self->pool_name;

    my $xml = eval {
        my $vmm  = $self->vmm;
        my $pool = $vmm->get_storage_pool_by_name($name);
        $pool->get_xml_description();
    } or return undef;

    my ($path) = $xml =~ m{<target>.*?<path>([^<]+)</path>};
    return $path;
}

=head1 LIBVIRT

All libvirt calls go through L<Sys::Virt>, which uses the transport of the
connection URI itself.  This code does not run C<virsh>.  It reaches libvirt
only by the URI it was given.

=head2 vmm

The L<Sys::Virt> connection.  The first call opens it and later calls return the
same one.  Dies if libvirt does not accept the connection.

=cut

sub vmm {
    my ($self) = @_;
    return $self->{vmm} if $self->{vmm};

    $self->require_client;

    # An empty URI lets libvirt select its default, as virsh does with no -c.
    my $uri = $self->explicit ? $self->uri : '';
    $self->{vmm} = eval { Sys::Virt->new( uri => $uri, readonly => 0 ) }
      or die "Could not connect to libvirt at " . $self->uri . ": $@\n";
    return $self->{vmm};
}

=head2 network_vmm

The connection that has the C<default> network and its leases, and the domains
of the system daemon.  That is L</vmm>, except on a session URI.  There it is a
read-only connection to the system daemon of the same host, as the same user,
because the NAT network belongs to the system daemon.  A read-only connection
needs no group: libvirt lets any user open one, and refuses every change on it.
The first call opens it, and later calls return the same one.

=cut

sub network_vmm {
    my ($self) = @_;
    return $self->vmm unless $self->is_session;
    return $self->{network_vmm} if $self->{network_vmm};

    $self->require_client;
    my $uri = $self->uri =~ s{/session\z}{/system}r;
    $self->{network_vmm} = eval { Sys::Virt->new( uri => $uri, readonly => 1 ) }
      or die "Could not open a read-only connection to libvirt at $uri: $@\n";
    return $self->{network_vmm};
}

# A domain lookup dies when there is no such domain, which is not an error for
# any caller here.  The connection opens outside the eval, so a hypervisor that
# we cannot reach does not look like "no such domain".
my sub domain ( $self, $name ) {
    my $vmm = $self->vmm;
    return eval { $vmm->get_domain_by_name($name) };
}

=head2 guest_names

The names of all domains that libvirt has here, running or not.

=cut

sub guest_names {
    my ($self) = @_;
    return map { $_->get_name } $self->vmm->list_all_domains();
}

=head2 domain_exists($name)

Returns 1 if libvirt has a domain of that name, running or not, and 0 if not.

=cut

sub domain_exists ( $self, $name ) { return defined domain( $self, $name ) ? 1 : 0 }

=head2 stop_domain($name)

Stops a domain and leaves it defined.  Returns 1 if the domain exists, and 0 if
it does not.  Dies if libvirt cannot stop it.

A rebuild that keeps the disk of a guest stops the guest but does not undefine
it.  qemu-img then writes the image directly, and the image gets corrupted if
qemu has it open.

=cut

sub stop_domain {
    my ( $self, $name ) = @_;
    my $domain = domain( $self, $name ) or return 0;

    return 1 unless $domain->is_active();
    eval { $domain->destroy(); 1 } or die "Could not stop $name: $@";
    return 1;
}

=head2 start_domain($name)

Starts a domain that is defined but not running.  Returns 1 if the domain
exists, and 0 if it does not.  A domain that is already running stays as it is.
Dies if libvirt cannot start it.

=cut

sub start_domain {
    my ( $self, $name ) = @_;
    my $domain = domain( $self, $name ) or return 0;

    return 1 if $domain->is_active();
    eval { $domain->create(); 1 } or die "Could not start $name: $@";
    return 1;
}

=head2 @actions = $hv->debug_actions()

Every action of F<bin/debug_boot>.  The tool was written against libvirt, and
each of its actions edits the definition of a domain, drives libguestfs on the
hypervisor, or asks libvirt for a screen.

=cut

sub debug_actions { return qw{console fetch hold shot vnc keys restore cat ls single} }

=head2 $xml = $hv->domain_definition($name)

The definition of a domain, as libvirt would define it again.

Inactive, so this is the definition and not the runtime state.  The runtime
state has allocated devices and aliases that libvirt cannot define.

Dies if there is no such domain.

=cut

sub domain_definition {
    my ( $self, $name ) = @_;

    my $domain = domain( $self, $name )
      or die "No domain called $name on " . $self->describe . "\n";

    return $domain->get_xml_description( Sys::Virt::Domain::XML_INACTIVE() );
}

=head2 $hv->restart_domain($name)

Stops a domain and starts it again, so that it boots with the definition it has
now.  Returns 1.

=cut

sub restart_domain {
    my ( $self, $name ) = @_;

    $self->stop_domain($name);

    # The pause came with this code from bin/debug_boot, and no commit says what
    # it is for.  qemu is still tearing the guest down when destroy returns, so
    # it is left in place.
    sleep $RESTART_SETTLE;
    $self->start_domain($name);

    return 1;
}

=head2 $path = $hv->console_log_path($name)

Where the console of this domain is captured on the hypervisor.

=cut

sub console_log_path { my ( $self, $name ) = @_; return "$CONSOLE_LOG_DIR/$name-console.log" }

=head2 $restarted = $hv->console_capture($name, wait =E<gt> $seconds)

Points the serial port of the domain at C<console_log_path> and restarts it, so
that the capture starts at the first line of the firmware.  Waits C<$seconds>
for the guest to boot, and returns 1: libvirt cannot read the output of a boot
that already happened.

Dies if the domain already writes its console to a file, which C<console_output>
reads and C<console_capture_off> undoes, or if it has no C<pty> serial port.

=cut

sub console_capture {
    my ( $self, $name, %opts ) = @_;

    my $xml = $self->domain_definition($name);
    my $log = $self->console_log_path($name);

    die "$name already logs its console to a file.  Read that capture rather than\n" . "starting another, and put the serial port back before capturing again.\n"
      if index( $xml, q{<serial type='file'} ) >= 0;

    # libvirt writes the serial output directly to this file.  Nothing must hold
    # a pty open.
    $xml =~ s{<serial[ ]type='pty'>}{<serial type='file'><source path='$log'/>}
      or die "$name has no pty serial port to redirect.\n";

    $self->define_domain($xml);
    $self->restart_domain($name);

    sleep( $opts{wait} // 0 );
    return 1;
}

=head2 $hv->console_capture_off($name)

Puts the serial port back to a C<pty>, undoing C<console_capture>.  Returns 1.

The domain has to be restarted for it to take effect.

=cut

sub console_capture_off {
    my ( $self, $name ) = @_;

    my $xml = $self->domain_definition($name);
    my $log = $self->console_log_path($name);

    # libvirt reformats the XML and puts <source> on a line of its own.  The
    # match is on the log path, because that is the part that is ours.
    $xml =~ s{<serial[ ]type='file'>\s*<source[ ]path='\Q$log\E'\s*/>}{<serial type='pty'>};

    $self->define_domain($xml);
    return 1;
}

=head2 $text = $hv->console_output($name)

What C<console_capture> has captured, or undef if the file is not there or is
empty.

=cut

sub console_output {
    my ( $self, $name ) = @_;

    # sudo, because libvirt writes the file as root.
    my $log = $self->console_log_path($name);
    return $self->capture_cmd("sudo -n cat '$log'") || undef;
}

=head2 ($advice, $port) = $hv->vnc_access($name)

The VNC port of the domain, and how to reach it.  The display listens on the
loopback of the hypervisor, so the advice is the ssh tunnel to it.

Dies if there is no such domain, or if it has no display with a port.  A
display with C<autoport='yes'> has C<port='-1'> until the domain runs.

=cut

sub vnc_access {
    my ( $self, $name ) = @_;

    my $domain = domain( $self, $name )
      or die "No domain called $name on " . $self->describe . "\n";

    # The port of the VNC display in the live definition.  A display with
    # autoport has port='-1' until the domain runs, which is no port.
    my ($port) =
      grep { $_ > 0 }
      map  { m{\bport='(-?\d+)'} ? $1 : () }
      grep { index( $_, q{type='vnc'} ) >= 0 } $domain->get_xml_description() =~ m{<graphics\b[^>]*>}g;
    die "$name has no display to connect to.\n" unless $port;

    my $through = $self->ssh_target // 'localhost';
    my $advice  = <<"TUNNEL";
$name has VNC on port $port, on the hypervisor's loopback.

  ssh -N -L $port:127.0.0.1:$port $through
  then point a VNC client at 127.0.0.1:$port

TUNNEL

    return ( $advice, $port );
}

=head2 domain_uuid($name)

The uuid that libvirt has for this domain, or undef when there is no such
domain.

A rebuild that keeps the disk does not undefine the domain, because that
discards the libvirt record of its snapshots.  libvirt refuses to define a name
again under a different uuid.  So the XML for that rebuild carries the existing
uuid.  A first build carries none, and libvirt makes one.

=cut

sub domain_uuid {
    my ( $self, $name ) = @_;
    my $domain = domain( $self, $name ) or return undef;

    return eval { $domain->get_uuid_string() };
}

=head2 annihilate_domain($name)

Stops and undefines a domain, with its nvram and its snapshot metadata.  A domain
that is already off is not an error.  Returns 1 if there was a domain to remove,
and 0 if not.  Dies if libvirt cannot undefine it.

=cut

sub annihilate_domain {
    my ( $self, $name ) = @_;
    my $domain = domain( $self, $name ) or return 0;

    $self->stop_domain($name);
    eval {
        $domain->undefine( Sys::Virt::Domain::UNDEFINE_NVRAM() | Sys::Virt::Domain::UNDEFINE_SNAPSHOTS_METADATA() );
        1;
    } or do {

        # An older libvirt, without nvram support for this domain type.
        eval { $domain->undefine(); 1 } or do {
            die "Could not undefine $name: $@";
        };
    };
    return 1;
}

=head2 lease_ip($network, %opts)

The address that libvirt leased on C<$network>, usually C<default>, or undef
when no lease matches.

=over 4

=item * C<mac>: only the lease of that interface.  dnsmasq filters on it, so the
match is exact.

=item * C<hostname>: leases whose hostname contains this string.  The guest
C<vm.example.test> also matches a lease of C<sub.vm.example.test>.  Use the MAC
when you can.  C<guest_mac> always gives one.

=item * C<exclude>: an address to skip.

=back

When several leases match, the result is the one that expires last.  That is
the most recent lease.  One MAC can hold several leases, because a rebuilt
guest gets a new address and the old lease stays until it expires.

=cut

sub lease_ip {
    my ( $self, $network, %opts ) = @_;
    my ($newest) = $self->lease_ips( $network, %opts );
    return $newest;
}

=head2 @ips = lease_ips($network, %opts)

Every matching address leased on C<$network>, newest first.  It takes the same
options as C<lease_ip>.  An empty list when there is no such network.  Use it
to find the old leases of a rebuilt guest, to release them.

=cut

sub lease_ips {
    my ( $self, $network, %opts ) = @_;

    my $vmm = $self->network_vmm;
    my $net = eval { $vmm->get_network_by_name($network) } or return ();

    # get_dhcp_leases filters by MAC on the hypervisor.
    my @leases = eval { $net->get_dhcp_leases( $opts{mac} ) };

    my @ips;
    foreach my $lease ( reverse sort { ( $a->{expirytime} // 0 ) <=> ( $b->{expirytime} // 0 ) } @leases ) {
        next unless $lease->{ipaddr};
        next
          if defined $opts{hostname}
          && !( defined $lease->{hostname} && $lease->{hostname} =~ m/\Q$opts{hostname}\E/ );
        next if defined $opts{exclude} && $lease->{ipaddr} eq $opts{exclude};
        push @ips, $lease->{ipaddr};
    }
    return @ips;
}

=head2 release_dhcp_lease($ip, $bridge)

Removes a stale lease, so that the lease table does not fill up.  C<$bridge>
defaults to L</lease_nic>.  Returns 1 if the release worked.  Returns 0 if
it failed, if C<$ip> is empty, or if there is no lease helper.

This is the only libvirt operation that runs a command.  libvirt gives DHCP
leases read-only, and C<virNetworkGetDHCPLeases> has no delete operation.  So
this runs the libvirt lease helper on the hypervisor, as root.

=cut

sub release_dhcp_lease {
    my ( $self, $ip, $bridge ) = @_;
    return 0 unless $ip;
    $bridge //= $self->lease_nic;

    my $helper = $self->lease_helper;
    unless ($helper) {
        warn "No libvirt lease helper found on the hypervisor, leaving the lease for $ip alone\n";
        return 0;
    }

    return $self->run_sudo( "VIR_BRIDGE_NAME=$bridge", $helper, qw{del ip}, $ip ) == 0 ? 1 : 0;
}

=head2 $path = $hv->lease_helper()

The path of the libvirt lease helper on the hypervisor, or undef when it has
none.  Distributions put it in one of two places.

=cut

sub lease_helper {
    my ($self) = @_;
    return List::Util::first { $self->file_exists($_) } @LEASE_HELPERS;
}

=head2 eject_cdrom($domain, $target)

Removes the cloud-init ISO from the drive, so that the guest does not boot it
again.  C<$target> defaults to C<sda>, where the domain XML puts it.  Returns 1
on success.  Returns 0, with a warning, if it fails or there is no such domain.

Call this only after the guest says that cloud-init is finished.  The seed must
stay in the drive while cloud-init can read it.  If you remove it earlier, the
guest gets no user, no keys and no netplan.

=cut

sub eject_cdrom {
    my ( $self, $name, $target ) = @_;
    $target //= 'sda';

    my $domain = domain( $self, $name ) or return 0;
    my $xml    = qq{<disk type='file' device='cdrom'><driver name='qemu' type='raw'/><target dev='$target' bus='sata'/><readonly/></disk>};

    my $flags = Sys::Virt::Domain::DEVICE_MODIFY_LIVE() | Sys::Virt::Domain::DEVICE_MODIFY_CONFIG();
    my $ok    = eval { $domain->update_device( $xml, $flags ); 1 };
    warn "Could not eject the cloud-init cdrom from $name: $@" unless $ok;
    return $ok ? 1 : 0;
}

=head1 BUILDING THINGS

The pool, its volumes, the cloud-init seed and the domain, made through libvirt.
The hypervisor owns what is on it, and this code adds one guest to it.

=head2 pool($name)

The storage pool object.  If the pool does not exist, this defines it, builds
it and sets it to start with the host.  It also starts a pool that is not
running.  C<$name> defaults to L</pool_name>.  Dies if libvirt cannot build or
start the pool.

=cut

sub pool {
    my ( $self, $name ) = @_;
    $name //= $self->pool_name;
    return $self->{_pools}{$name} if $self->{_pools}{$name};

    my $pool = eval { $self->vmm->get_storage_pool_by_name($name) } // $self->define_pool( $name, $self->pool_path );

    if ( !$pool->is_active() ) {
        eval { $pool->create(); 1 } or do {
            die "Could not start the storage pool $name: $@";
        };
    }
    return $self->{_pools}{$name} = $pool;
}

=head2 $pool = $hv->define_pool($name, $path, %permissions)

Defines a directory pool C<$name> at C<$path>, builds it and sets it to start
with the host, and returns the pool object, which is not started.  Dies if
libvirt cannot build it.

C<%permissions> takes C<owner> and C<group>, as numeric ids, and C<mode>.
libvirt applies them to the directory when it builds the pool, and again on
every later build, so a C<chown> by hand does not last.  Without them, libvirt
uses its defaults.

=cut

sub define_pool {
    my ( $self, $name, $path, %permissions ) = @_;
    print "Defining storage pool $name at $path\n";

    my $permissions = join q{}, map { "<$_>$permissions{$_}</$_>" } grep { defined $permissions{$_} } qw{mode owner group};
    $permissions = "<permissions>$permissions</permissions>" if $permissions;

    my $pool = $self->vmm->define_storage_pool(<<"XML");
<pool type='dir'>
  <name>$name</name>
  <target><path>$path</path>$permissions</target>
</pool>
XML
    eval { $pool->build( Sys::Virt::StoragePool::BUILD_NEW() ); 1 } or do {
        die "Could not build the storage pool $name at $path: $@";
    };
    $pool->set_autostart(1);

    return $pool;
}

=head2 volume($name, $pool)

The volume C<$name> in the pool C<$pool>, or undef when there is no such
volume.  C<$pool> defaults to L</pool_name>.

=head2 volume_path($name, $pool)

The path of the file of that volume, or undef when there is no such volume.  A
disk in the domain XML needs this path.

=cut

sub volume {
    my ( $self, $name, $pool ) = @_;
    return eval { $self->pool($pool)->get_volume_by_name($name) };
}

sub volume_path {
    my ( $self, $name, $pool ) = @_;
    my $volume = $self->volume( $name, $pool ) or return undef;
    return eval { $volume->get_path() };
}

=head2 $name = image_volume_name($url)

The name of the volume that C<base_image> keeps the image at C<$url> in.  The
file name keeps it readable in C<virsh vol-list>.  The hash keeps two images with
one file name apart, such as the image of a mirror and the image of the archive.

=cut

sub image_volume_name ($url) {
    my $file = File::Basename::basename( URI->new($url)->path // q{} ) =~ s/[^\w.-]/_/gr;
    return 'baseimage-' . $file . '-' . substr( Digest::SHA::sha256_hex($url), 0, 12 );
}

=head2 base_image($url, $name)

Returns the path of the base image under the disk of a guest.  If the pool has
no volume C<$name>, this downloads C<$url> to the hypervisor first.  Dies if
there is no image and no URL, or if the download fails.

C<$name> defaults to a name of C<$url>: C<baseimage->, the file name in the URL,
and the start of a hash of the whole URL.  So each image has a volume of its own,
and a guest of one release is never built over the image of another.  Without a
URL, it defaults to C<baseimage-qcow2>, the one volume that a pool held before.

libvirt cannot fetch a URL.  So this runs curl on the hypervisor, into the pool
directory, and then refreshes the pool.  curl runs without sudo on purpose.  If
this account cannot write to the pool directory, the pool is misconfigured, and
sudo hides that.

=cut

sub base_image {
    my ( $self, $url, $name ) = @_;
    $name //= defined $url ? image_volume_name($url) : 'baseimage-qcow2';

    my $path = $self->volume_path($name);
    return $path if $path;

    die "No image URL configured, and no $name in the pool to fall back on\n"
      unless $url;

    $path = $self->pool_path . "/$name";
    print "Fetching the base image from $url\n";

    # Download to a partial name first, because a half-downloaded file that
    # libvirt already sees is worse than no file.
    my $partial = "$path.partial";
    $self->run_cmd( qw{curl -fL --retry 3 -o}, $partial, $url ) == 0
      or die "Could not fetch $url onto " . $self->describe . "\n";

    $self->run_cmd( 'mv', $partial, $path ) == 0 or die "Could not put the base image in place\n";
    $self->refresh_pool();

    return $self->volume_path($name) // $path;
}

# The three characters that XML reads as markup, escaped, for a name that goes
# into the XML libvirt is handed.
my sub xml_escape ($str) {
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    return $str;
}

=head2 create_disk($name, %opts)

Makes a qcow2 volume over the base image, if the volume does not exist, and
returns its path.  C<backing> is the path of the backing image.  C<capacity> is
the size in bytes.  Dies if there is no C<capacity>.

C<qcow2_tuning> sets the layout, and explains it.  The cluster size and the
subcluster allocation are fixed when the image is made.  So this does not
change a disk that already exists, which holds the filesystem of a guest.

It also takes the C<trog-pristine> snapshot of the new, empty disk.  If that
fails, it gives a warning.  A rebuild then deletes the disk, and
C<rollback_possible> says no.

=cut

sub create_disk {
    my ( $self, $name, %opts ) = @_;

    my $existing = $self->volume_path($name);
    return $existing if $existing;

    my $capacity = $opts{capacity} or die "No size given for the disk $name\n";
    my $backing  = $opts{backing};

    my $backing_xml =
      $backing
      ? "<backingStore><path>" . xml_escape($backing) . "</path><format type='qcow2'/></backingStore>"
      : '';

    print "Creating disk $name ($capacity bytes)" . ( $backing ? " over $backing" : '' ) . "\n";

    my %tuning = $self->qcow2_tuning($capacity);
    my $target = "<format type='qcow2'/>";

    if ( $tuning{cluster_size} ) {
        print "  ...with $tuning{cluster_size} byte clusters, so qemu's metadata cache still covers a disk this size\n";
        $target .= "<clusterSize unit='bytes'>$tuning{cluster_size}</clusterSize>";
    }

    if ( $tuning{extended_l2} ) {
        print "  ...with subcluster allocation, so a small write into this overlay does not rewrite a whole cluster\n";
        $target .= '<features><extended_l2/></features>';
    }

    my $volume = $self->pool->create_volume(<<"XML");
<volume>
  <name>@{[ xml_escape($name) ]}</name>
  <capacity unit='bytes'>$capacity</capacity>
  <target>$target</target>
  $backing_xml
</volume>
XML

    # Take the pristine snapshot now, because the overlay is never empty again.
    #
    # No `; 1` inside the eval.  qemu-img refusing the disk is a false return,
    # not an exception, so the block must catch both.
    eval { $self->snapshot_disk( $name, $PRISTINE_SNAPSHOT ) } or do {
        warn "Could not take the $PRISTINE_SNAPSHOT snapshot of $name on " . $self->describe . ": " . ( $@ || "qemu-img would not take it.\n" ) . "This guest rebuilds by deleting its disk, and cannot be rolled back.\n";
    };

    return $volume->get_path();
}

=head2 delete_volume($name, $pool)

Removes a volume.  Returns 1 if it did.  Returns 0 if there was no such volume,
or, with a warning, if libvirt cannot delete it.

=head2 refresh_pool($name)

Makes libvirt read the pool directory again.  Use it after something other than
libvirt adds a file there.  C<$name> defaults to L</pool_name>.  Returns 1, and
dies if the refresh fails.

libvirt refuses a refresh while a job of its own runs on the pool, such as the
volume that another provision is creating.  That refusal says that the pool is
busy, not broken, so this says so once, asks again every C<$POOL_BUSY_INTERVAL>
seconds, and dies only after C<$POOL_BUSY_WAIT> seconds.  Any other refusal
dies at once.

=cut

sub delete_volume {
    my ( $self, $name, $pool ) = @_;
    my $volume = $self->volume( $name, $pool ) or return 0;
    eval { $volume->delete(0); 1 } or do { warn "Could not delete the volume $name: $@"; return 0 };
    return 1;
}

sub refresh_pool {
    my ( $self, $name ) = @_;
    my $pool     = $name // $self->pool_name;
    my $deadline = time + $POOL_BUSY_WAIT;
    my $said;

    while ( !eval { $self->pool($name)->refresh(); 1 } ) {
        my $error = $@;
        die "Could not refresh the storage pool $pool: $error" if $error !~ m/asynchronous[ ]jobs[ ]running/ || time >= $deadline;

        print "The storage pool $pool is busy with another job, so the refresh waits for it\n" unless $said++;
        sleep $POOL_BUSY_INTERVAL;
    }
    return 1;
}

=head2 cloudinit_iso($domain, %files)

Makes the cloud-init seed ISO on the hypervisor, in the pool, and returns its
path.  C<%files> maps each NoCloud file name to its contents: C<user-data>,
C<meta-data> and C<network-config>.  Dies if a file cannot be written or the ISO
cannot be made.

=cut

sub cloudinit_iso {
    my ( $self, $domain, %files ) = @_;

    my $name    = "$domain-cloudinit.iso";
    my $workdir = "/tmp/trog-cloudinit-$domain-$$";
    my $path    = $self->pool_path . "/$name";

    $self->mkpath($workdir) or die "Could not make $workdir on " . $self->describe . "\n";
    foreach my $file ( sort keys %files ) {
        $self->write_text( "$workdir/$file", $files{$file} )
          or die "Could not write $file for $domain on " . $self->describe . "\n";
    }

    my $maker = $self->iso_maker;
    print "Building the cloud-init seed for $domain with $maker\n";

    # -volid cidata is necessary, because NoCloud finds its seed by that label.
    my @cmd = $maker eq 'xorriso' ? ( $maker, '-as', 'mkisofs' ) : ($maker);
    my $rc  = $self->run_cmd(
        @cmd, qw{-output}, $path, qw{-volid cidata -joliet -rock},
        map { "$workdir/$_" } sort keys %files
    );

    $self->run_cmd( qw{rm -rf}, $workdir );
    die "Could not build the cloud-init seed for $domain\n" if $rc;

    $self->refresh_pool();
    return $path;
}

=head2 iso_maker

The first of C<xorriso>, C<genisoimage> or C<mkisofs> that the hypervisor has.
Dies if it has none of them.

=cut

sub iso_maker {
    my ($self) = @_;
    return $self->{_iso_maker} if $self->{_iso_maker};

    foreach my $maker (qw{xorriso genisoimage mkisofs}) {
        next if $self->run_cmd( 'sh', '-c', "command -v $maker >/dev/null 2>&1" );
        return $self->{_iso_maker} = $maker;
    }

    die 'No ISO builder on ' . $self->describe . ": install xorriso or genisoimage.\n" . "cloud-init reads its configuration off a small ISO, and something has to make it.\n";
}

=head2 define_domain($xml, %opts)

Defines a domain from XML, starts it, and returns the domain object.
C<autostart> sets it to start with the host, and defaults to true.  Dies if
libvirt cannot set the domain to start with the host, or cannot start it.

=cut

sub define_domain {
    my ( $self, $xml, %opts ) = @_;

    my $domain = $self->vmm->define_domain($xml);
    if ( $opts{autostart} // 1 ) {
        eval { $domain->set_autostart(1); 1 } or do {
            die 'Could not set ' . $domain->get_name() . " to start with the host: $@";
        };
    }

    # start_domain looks the domain up by name, and that lookup can find
    # nothing.  A domain that did not start must not return as if it did.
    $self->start_domain( $domain->get_name() )
      or die 'Could not start ' . $domain->get_name() . ": libvirt has no such domain, having just defined it\n";

    return $domain;
}

=head1 ADAPTERS

A block of F<hypervisors.conf> names the bridges of the adapters of a guest in
two lists:

    dhcp_nics       = virbr0
    static_nics     = virbr1, br0
    ip_pool_virbr1  = 10.0.0.0/25
    gateway_virbr1  = 10.0.0.1
    ip_pool_br0     = 192.0.2.64/26

=over 4

=item C<dhcp_nics>

Each adapter takes a lease.  The first one takes the lease that this machine
finds the guest by, as L</lease_nic> says.  Its default is the bridge of the
C<default> network.

=item C<static_nics>

Each adapter gets an address from its own pool, C<ip_pool_NIC> or
C<ip_addresses_NIC>.  See L<Trog::HV/nic_pool($nic)>.  The first one gets the
address of the guest, the one in C<ipmap> and in its records, and the only
default route, through C<gateway_NIC>.  The others get only their own subnet.
The default is none.

=back

The adapters are in the domain in that order, C<dhcp_nics> and then
C<static_nics>, and the place of each one is its I<index>, from 0.  The index
decides its MAC, L</guest_mac($domain, $index)>, its PCI slot, L</nic_slots>,
and its name, L</nic_names>.  So the adapter of the lease is always index 0,
and a block with one bridge in each list gives its guests the MACs, slots and
names that the two adapters of a guest always had.

C<build> dies when a list names something that is not a bridge, when a bridge
is named twice, when a static adapter has no pool, when the first has no
gateway, and when a pool or a gateway is for a bridge that C<static_nics> does
not name.  L<Trog::Hypervisors> refuses a block that still names the keys that
these replaced: see L<Trog::HV/replaced_keys>.

=head1 GUEST IDENTITY

=head2 guest_mac($domain, $index)

The MAC address for interface C<$index> of a guest.  C<$index> defaults to 0.
The address comes from the domain name, so it is the same on every build.

When libvirt makes the MACs, a rebuilt guest gets new ones.  It then gets a new
DHCP lease, and the old lease stays until it expires.  A network configuration
then cannot tell which interface is which.  A fixed MAC keeps the lease and
names the interface exactly.

C<52:54:00> is the QEMU/KVM prefix.  The other three bytes come from a digest of
the domain and the interface index.  Two guests can get the same MAC, but that
becomes likely only with a few thousand guests.

=head2 dhcp_nics

The bridges of the adapters of a guest that take a lease, from C<dhcp_nics> in
the block of F<hypervisors.conf>, in order.  The first one takes the lease that
this machine reaches the guest by: see L</lease_nic>.  Without C<dhcp_nics>, it
is L</lease_nic> alone.

=head2 nic_bridges

The bridge of each adapter of a guest, by index: C<dhcp_nics>, then
C<static_nics>.  See L</ADAPTERS>.

=head2 nic_network($nic)

The block of the network of the bridge C<$nic>, such as C<10.0.0.0/24>: the
network of C<gateway_NIC>, or of the first address of the pool when the block
names no gateway, with the prefix of C<nic_prefix_length>.

=head2 address_index

The index of the adapter whose address is the address of the guest, the first
of C<static_nics>, or undef when the block names none.  L</guest_mac($domain,
$index)> of it is the MAC that the network configuration of the guest matches
for that address.

=head2 nic_slots

The PCI slots of the adapters, by index: 3, 4, and so on.  systemd names a PCI NIC after its hotplug slot.  So fixed slots keep the
names the same when the device list changes.

=head2 nic_prefix

The start of the name that a guest here gives a PCI network interface, before
the slot number.

The name depends on the machine type, not on the guest, so the hypervisor gives
it.  The domain XML asks for i440fx.  There, the predictable naming of systemd
gives C<ensN> for a device in hotplug slot N.  Other machine types give other
names, most often C<enpNsM>.  A hypervisor that builds its guests differently
overrides this.

=head2 nic_names

The names that the adapters of a guest get, by index.

This is a prediction.  cloud-init finds each interface by its MAC, which we
choose, and gives it the name in the configuration.  So each interface gets the
correct configuration even when the kernel names it differently.  This method
gives the name after cloud-init renames it.

=cut

sub guest_mac {
    my ( $self, $domain, $index ) = @_;
    $index //= 0;

    my $digest = Digest::SHA::sha256_hex("$domain/$index");
    return join( ':', qw{52 54 00}, $digest =~ m/\A(\N\N)(\N\N)(\N\N)/ );
}

# The PCI slot of the first adapter of a guest.  Slots 0 to 2 of i440fx are the
# host bridge, the ISA bridge and the VGA card.
my $FIRST_NIC_SLOT = 3;

sub dhcp_nics ($self) {
    my @nics = $self->setting_list('dhcp_nics');
    return @nics ? @nics : $self->lease_nic;
}

sub nic_bridges ($self) { return ( $self->dhcp_nics, $self->static_nics ) }

# How many adapters take a lease, without asking the hypervisor: those of
# dhcp_nics, or the one of lease_nic.
my sub dhcp_count ($self) {
    my @nics = $self->setting_list('dhcp_nics');
    return @nics || 1;
}

sub nic_slots ($self) {
    my @static = $self->static_nics;
    my $count  = dhcp_count($self) + @static;
    return map { $FIRST_NIC_SLOT + $_ } 0 .. $count - 1;
}

sub nic_network ( $self, $nic ) {
    my $pool  = $self->nic_pool($nic);
    my ($any) = map { s{/\d+\z}{}r } @{ $pool->{cidr} // [] }, @{ $pool->{addresses} // [] };
    my $at    = $self->nic_gateway($nic) // $any // die "$nic names neither a gateway nor a pool, so it has no network\n";
    return Trog::HV::network_of( $at, $self->nic_prefix_length($nic) );
}

sub address_index ($self) { return defined $self->address_nic ? dhcp_count($self) : undef }

sub nic_prefix { return 'ens' }

=head2 guest_disks

C<vd*>.  The domain XML puts each disk of a guest on the C<virtio> bus, which
names it C<vdN>.  The seed is a CD-ROM on SATA, C<sda>, so C<sd*> is not one of
the disks.

=cut

sub guest_disks { return ('vd*') }

sub nic_names {
    my ($self) = @_;
    my $prefix = $self->nic_prefix;
    return map { "$prefix$_" } $self->nic_slots;
}

=head1 SNAPSHOTS

=head2 snapshot_names($domain)

The names of all snapshots of the domain, oldest first.  An empty list when
there is no such domain.  libvirt returns them in no fixed order, so this sorts
them by creation time.  C<bin/restore --latest> and C<--oldest> need that order.

=cut

sub snapshot_names {
    my ( $self, $name ) = @_;
    my $domain = domain( $self, $name ) or return ();

    my @snaps = eval { $domain->list_all_snapshots() };
    return () unless @snaps;

    # <creationTime> is seconds since the epoch.  A snapshot without one sorts
    # first, as the oldest.
    my @dated = map {
        my $xml = eval { $_->get_xml_description() } // q{};
        my ($created) = $xml =~ m{<creationTime>(\d+)</creationTime>};
        +{ name => $_->get_name(), created => $created // 0 };
    } @snaps;
    return map { $_->{name} }
      sort { $a->{created} <=> $b->{created} or $a->{name} cmp $b->{name} }
      grep { $_->{name} } @dated;
}

=head2 snapshot_current_name($domain)

The name of the current snapshot of the domain, or undef if it has none.

=cut

sub snapshot_current_name {
    my ( $self, $name ) = @_;
    my $domain = domain( $self, $name )               or return undef;
    my $snap   = eval { $domain->current_snapshot() } or return undef;
    return $snap->get_name();
}

=head2 create_snapshot($domain, $name, disk_only =E<gt> $bool, leave_down =E<gt> $bool)

Takes an atomic snapshot.  Returns 1 if libvirt took it, and 0, with a warning,
if not.  If C<$name> is undef, libvirt names the snapshot after the current
time.  Dies if there is no such domain.

A running guest gets a B<full system> snapshot.  Its memory goes into the qcow2
with the disk, so a revert resumes the guest and does not boot it.  libvirt
takes only this kind of snapshot of a running domain.

C<disk_only> stops the guest first and takes a snapshot of the disk only.  Then
it starts the guest again if it was running, also when the snapshot fails.  A
snapshot with no memory is smaller and faster, and a revert to it boots the
guest.

C<leave_down> keeps the guest stopped after a C<disk_only> snapshot.  It is for
a caller that is about to take the guest apart.

A guest that is already off has no memory, so it always gets a snapshot of the
disk only.

=cut

sub create_snapshot {
    my ( $self, $name, $snapname, %opts ) = @_;
    my $domain = domain( $self, $name ) or die "No such domain $name on " . $self->uri . "\n";

    # libvirt takes a full system snapshot of a running guest, or a disk-only
    # snapshot of a stopped guest, and no other kind.  Any other request is error
    # 84, "live snapshot creation is supported only during full system snapshots".
    my $live = !$opts{disk_only} && $domain->is_active();

    # Set before the stop below, because the stop changes is_active.
    my $resume = $opts{disk_only} && !$opts{leave_down} && $domain->is_active();

    $self->stop_domain($name) if $opts{disk_only};

    my $xml = '<domainsnapshot>';
    $xml .= '<name>' . xml_escape($snapname) . '</name>' if $snapname;

    # libvirt reads this element to tell the two kinds apart.  Without it, the
    # request is for the disk only.
    $xml .= "<memory snapshot='internal'/>" if $live;
    $xml .= '</domainsnapshot>';

    # No CREATE_LIVE.  That flag tells libvirt not to pause the guest while it
    # writes the memory, which it allows only for memory outside the disk.  Here
    # the memory goes inside the disk, so the flag makes the request invalid.
    my $flags = Sys::Virt::DomainSnapshot::CREATE_ATOMIC();

    my $ok = eval { $domain->create_snapshot( $xml, $flags ); 1 };
    warn "Snapshot of $name failed: $@" unless $ok;

    # Also after a failed snapshot, because a failure is no reason to leave a
    # running guest stopped.
    $self->start_domain($name) if $resume;

    return $ok ? 1 : 0;
}

=head2 revert_snapshot($domain, $name)

Reverts the domain to the snapshot C<$name> and leaves it running.  Returns 1 on
success.  Returns 0 if there is no such domain or snapshot, or, with a warning,
if the revert fails.

=cut

sub revert_snapshot {
    my ( $self, $name, $snapname ) = @_;
    my $domain = domain( $self, $name )                            or return 0;
    my $snap   = eval { $domain->get_snapshot_by_name($snapname) } or return 0;

    my $ok = eval { $snap->revert_to( Sys::Virt::DomainSnapshot::REVERT_RUNNING() ); 1 };
    warn "Revert of $name to $snapname failed: $@" unless $ok;
    return $ok ? 1 : 0;
}

=head1 HYPERVISOR FACTS

What the hypervisor has and what it can do: its TPM, its libvirt and qemu
versions, its disk features, its storage pool and its network bridges.  Each
answer is cached for the life of the object.

=head2 has_tpm

True when guests built here get a TPM.

Two conditions must both be true.  First, C<swtpm> must be installed.  The TPM
of the guest is emulated by one C<swtpm> process for each domain, and libvirt
cannot start a program that is not there.  Second, the hypervisor must have a
real TPM of its own.

An emulated TPM keeps its state in a file on the hypervisor, next to the disk
image of the guest.  A person who takes the disk can also take that file.  So
the emulated TPM protects a key only when the disk of the hypervisor is
protected by hardware.  A TPM that cannot keep a secret is worse than no TPM,
because software on the guest uses it and trusts it.

=cut

sub has_tpm {
    my ($self) = @_;
    return $self->{has_tpm} if defined $self->{has_tpm};

    # tpmrm0, not tpm0, because software on a current kernel opens the resource
    # manager.  A machine with tpm0 and no tpmrm0 has a TPM that the kernel did
    # not start correctly.
    my $answer = $self->capture_cmd(q{test -c /dev/tpmrm0 && command -v swtpm > /dev/null && echo yes});
    chomp $answer if defined $answer;

    return $self->{has_tpm} = ( ( $answer // '' ) eq 'yes' ) ? 1 : 0;
}

=head2 libvirt_version, qemu_version

The libvirt and qemu versions of the hypervisor, as libvirt encodes a version:
C<major * 1_000_000 + minor * 1_000 + release>.  Both come from the connection,
so each hypervisor gives its own versions.

Zero when the connection does not give a version.  Every capability check below
then answers no.  So a hypervisor that does not answer gets a plain domain, and
not XML that it can refuse.

=cut

sub libvirt_version {
    my ($self) = @_;
    return $self->{libvirt_version} //= eval { $self->vmm->get_library_version() } || 0;
}

sub qemu_version {
    my ($self) = @_;
    return $self->{qemu_version} //= eval { $self->vmm->get_version() } || 0;
}

# Each disk tuning setting that we can write, and the versions that accept it.
#
# The versions are the ones that the libvirt formatdomain and formatstorage
# documentation gives for each attribute.  You can compare each entry with that
# documentation.
#
# libvirt and qemu are separate checks because they fail in different ways.  If
# libvirt cannot parse the XML, the domain does not define, and we know at once.
# If libvirt parses it and qemu does not have the feature, the domain defines
# but does not start, and we know only later.
my %DISK_FEATURE = (
    io_uring         => { libvirt => '6.3.0', qemu => '5.0.0' },
    discard          => { libvirt => '1.0.6' },
    detect_zeroes    => { libvirt => '2.0.0' },
    discard_no_unref => { libvirt => '9.5.0',  qemu => '8.1.0' },
    iothread         => { libvirt => '1.2.8',  qemu => '2.1.0' },
    iothread_mapping => { libvirt => '10.0.0', qemu => '9.0.0' },
    queues           => { libvirt => '3.9.0' },
    metadata_cache   => { libvirt => '7.0.0' },
    blockio          => { libvirt => '0.10.2' },
    iotune           => { libvirt => '0.9.8' },
    cluster_size     => { libvirt => '7.4.0', qemu_img => 'cluster_size' },
    extended_l2      => { libvirt => '8.0.0', qemu_img => 'extended_l2' },
);

=head2 supports($feature)

Returns 1 if this hypervisor accepts the disk tuning setting C<$feature>, and 0
if not.  The names are the keys of C<%DISK_FEATURE> in the source.  Dies for any
other name.  The answer is cached, because a build asks the same questions for
each disk.

C<cache> is not in the table, because every libvirt accepts it.  Whether the
filesystem of the pool can do a given cache mode is a different question.
L</pool_takes_direct_io> answers it.

=cut

# Encodes a dotted version the way libvirt does, so that it compares directly
# with what the connection reports.
my sub version_number ($version) {

    # A character class, not an escape.  split always takes a pattern, so '.'
    # splits on every character, and perlcritic calls m/\./ a substring match.
    my ( $major, $minor, $release ) = split( m/[.]/, $version );
    return ( $major * 1_000_000 ) + ( $minor * 1_000 ) + ( $release // 0 );
}

sub supports {
    my ( $self, $feature ) = @_;
    my $needs = $DISK_FEATURE{$feature} or die "No such disk feature as '$feature'\n";

    # In this order on purpose.  The qemu-img probe runs a command on the
    # hypervisor, which is not necessary if libvirt is too old for the option.
    return $self->{supports}{$feature} //=
      ( $self->libvirt_version >= version_number( $needs->{libvirt} ) && ( !$needs->{qemu} || $self->qemu_version >= version_number( $needs->{qemu} ) ) && ( !$needs->{qemu_img} || $self->qemu_img_options->{ $needs->{qemu_img} } ) ) ? 1 : 0;
}

=head2 qemu_img_options

The qcow2 creation options that C<qemu-img> on this hypervisor knows, as a
hashref with each option name as a key.

libvirt makes a qcow2 volume with C<qemu-img create> and passes it the options
from the volume XML.  If qemu does not know an option, the volume is not made.
The volume XML accepted some of these options before qemu had them.  So the
libvirt version alone does not answer the question.

An empty hashref when qemu-img does not answer.  Then the disk gets none of the
optional features.

=cut

sub qemu_img_options {
    my ($self) = @_;
    return $self->{qemu_img_options} if $self->{qemu_img_options};

    # -o help lists the options for the format and exits.  It needs no filename.
    my $help    = $self->capture_cmd('qemu-img create -f qcow2 -o help 2>/dev/null') // '';
    my %options = map { $_ => 1 } ( $help =~ m/^\s+(\w+)=/gm );

    print "Could not ask qemu-img on " . $self->describe . " which qcow2 options it takes,\n" . "so this disk gets none of the optional ones.\n"
      unless %options;

    return $self->{qemu_img_options} = \%options;
}

=head2 pool_fstype

The type of the filesystem under the storage pool, as C<stat -f> names it, or
an empty string when C<stat> does not answer.  It names the filesystem in the
message when the pool does not take O_DIRECT, and tells ZFS apart.
L</pool_takes_direct_io> decides the cache mode.

=cut

sub pool_fstype {
    my ($self) = @_;
    return $self->{pool_fstype} //= $self->path_fstype( $self->pool_path );
}

=head2 $type = $hv->path_fstype($path)

The type of the filesystem at C<$path> on the hypervisor, as C<stat -f> names
it, or an empty string when C<stat> does not answer.  L</pool_fstype> asks it
of the pool.  F<bin/runner_account> asks it of the directory that a new pool
goes under, before the pool exists.

=cut

sub path_fstype {
    my ( $self, $path ) = @_;

    # capture_cmd takes a shell string, and the path can come from a
    # configuration file.
    my $quoted = Trog::Utils::shell_quote($path);

    my $type = $self->capture_cmd("stat -f -c %T $quoted 2>/dev/null") // '';
    chomp $type;

    return $type;
}

=head2 pool_takes_direct_io

Returns 1 if a file in the storage pool can be opened C<O_DIRECT> and written
to, and 0 if not.  That is all that C<cache='none'> needs from a filesystem.
Without it, the domain defines but does not start.

The method asks the filesystem, because the filesystem name does not give the
answer.  tmpfs takes an O_DIRECT write on a current kernel.  ZFS has Direct I/O
from OpenZFS 2.3, but the feature flags of the pool and the C<direct> property
of the dataset also control it.

So the method writes 4K with O_DIRECT into the pool directory, which is the same
open that qemu does.  It runs without sudo, for the reason that C<base_image>
gives.

=cut

sub pool_takes_direct_io {
    my ($self) = @_;
    return $self->{pool_takes_direct_io} if defined $self->{pool_takes_direct_io};

    my $probe = $self->pool_path . "/.odirect-probe.$$";

    # dd, not perl, because we ask for nothing to be installed on the
    # hypervisor, and coreutils is always there.  It fails if the filesystem
    # refuses the O_DIRECT open or the write.
    my $taken = $self->run_cmd(
        'sh', '-c',
        'dd if=/dev/zero of="$1" bs=4096 count=1 oflag=direct >/dev/null 2>&1; status=$?; rm -f "$1"; exit $status',
        'sh', $probe,
    ) == 0;

    return $self->{pool_takes_direct_io} = $taken ? 1 : 0;
}

=head2 zfs_version

The OpenZFS version on this hypervisor, or undef when there is no ZFS.

It is used only in the message for a ZFS pool that refuses an O_DIRECT write.
Direct I/O arrived in 2.3, so the version tells the operator to upgrade, or to
change the configuration of the pool.

=cut

sub zfs_version {
    my ($self) = @_;
    return $self->{zfs_version} if exists $self->{zfs_version};

    my $version = $self->capture_cmd('cat /sys/module/zfs/version 2>/dev/null') // '';
    chomp $version;

    return $self->{zfs_version} = $version ? $version : undef;
}

# The default qemu cluster size, and the size for a disk too large for the
# metadata cache.
my $QCOW2_DEFAULT_CLUSTER = 64 * $Provisioner::Vars::KB;
my $QCOW2_LARGE_CLUSTER   = $Provisioner::Vars::MB;

# The default qemu memory for qcow2 metadata, and the most that we ask for.  Both
# are for each running domain, in host memory that Trog::Hypervisors does not
# count.
my $QCOW2_METADATA_DEFAULT = 32 * $Provisioner::Vars::MB;
my $QCOW2_METADATA_CAP     = 256 * $Provisioner::Vars::MB;

# Above this size, the default metadata cache does not cover the whole image.
# qcow2_tuning gives the arithmetic.
my $QCOW2_LARGE_DISK = 128 * $Provisioner::Vars::GB;

=head2 qcow2_tuning($capacity)

The layout for a qcow2 of C<$capacity> bytes on this hypervisor.  Returns a hash
with C<extended_l2> (subcluster allocation, 1 or 0), and C<cluster_size> and
C<metadata_cache> in bytes when they differ from the qemu defaults.

Two facts decide the layout, and they conflict.

First, every guest disk here is an overlay on the shared base image.  Without
C<extended_l2>, an overlay allocates a whole cluster at a time.  A 4K write into
an empty 64K cluster reads 64K from the backing file and writes 64K back.
Subclusters make the unit of allocation a 32nd of a cluster, which stops most of
that.  So C<extended_l2> is on wherever qemu accepts it.

Second, an extended L2 entry is twice as wide, so the metadata cache covers half
as much of the image.  The default qemu cache of 32 MiB covers 256 GiB at the
default 64 KiB cluster, and 128 GiB with extended entries.  Above that, random
I/O must read L2 tables from the disk.

A 1 MiB cluster covers 16 times as much, but its subclusters are 32 KiB, not
2 KiB.  So only a disk larger than 128 GiB gets the large cluster.  A disk that
still needs more cache gets a larger metadata cache, up to 256 MiB.  Each of
the three applies only where L</supports($feature)> says the hypervisor takes it.

=cut

sub qcow2_tuning {
    my ( $self, $capacity ) = @_;

    my %tuning = ( extended_l2 => $self->supports('extended_l2') ? 1 : 0 );

    # One L2 entry for each cluster, twice as wide when it also holds the
    # subcluster allocation bitmap.
    my $entry = $tuning{extended_l2} ? 16 : 8;

    $tuning{cluster_size} = $QCOW2_LARGE_CLUSTER
      if $capacity > $QCOW2_LARGE_DISK && $self->supports('cluster_size');

    my $cluster = $tuning{cluster_size} // $QCOW2_DEFAULT_CLUSTER;
    my $wanted  = int( $capacity / $cluster ) * $entry;

    return %tuning if $wanted <= $QCOW2_METADATA_DEFAULT || !$self->supports('metadata_cache');

    $tuning{metadata_cache} = $wanted < $QCOW2_METADATA_CAP ? $wanted : $QCOW2_METADATA_CAP;
    return %tuning;
}

=head2 $hv->disk_reusable($domain, $capacity)

Returns 1 if a rebuild can keep the disk of this guest, and 0 if it must make
a new one.  The answer is 1 only when the disk exists, has C<$capacity> bytes,
and has the layout that C<qcow2_tuning> gives now.

The layout is part of the question because the image cannot change it later.
C<qcow2_tuning> uses both the capacity and what the hypervisor supports.  If qemu
got C<extended_l2> after the last build, the old image does not have it.
Keeping that image keeps the old layout for the life of the guest.

=cut

sub disk_reusable {
    my ( $self, $domain, $capacity ) = @_;

    return 0 unless $capacity;
    my $volume = $self->volume("$domain-qcow2") or return 0;
    my $info   = eval { $volume->get_info() }   or return 0;
    return 0 unless ( $info->{capacity} // 0 ) == $capacity;

    # Read from the image, because nothing here records the layout of a disk.
    my %wanted = $self->qcow2_tuning($capacity);
    my $has    = $self->disk_layout("$domain-qcow2") or return 0;

    return 0 unless ( $has->{cluster_size} // 0 ) == ( $wanted{cluster_size} // $QCOW2_DEFAULT_CLUSTER );
    return 0 unless ( $has->{extended_l2} ? 1 : 0 ) == ( $wanted{extended_l2} ? 1 : 0 );
    return 1;
}

=head2 $hv->rollback_possible($domain, capacity =E<gt> $bytes)

Returns 1 if a snapshot taken now still exists after the rebuild, and 0 if not.

A libvirt snapshot is inside the qcow2 of the guest.  So the snapshot survives
only if the rebuild keeps the disk, which C<disk_reusable> decides.  The disk
must also hold the C<trog-pristine> snapshot for the rebuild to revert to.  A
first build has no guest to go back to, so the answer is 0.

=cut

sub rollback_possible {
    my ( $self, $domain, %opts ) = @_;

    return 0 unless $self->domain_exists($domain);
    return 0 unless $self->disk_reusable( $domain, $opts{capacity} );

    # Some reusable disks have no pristine snapshot.  Without this check, the
    # revert fails in the middle of the rebuild, after the rollback point is
    # taken and announced.
    return ( grep { $_ eq $PRISTINE_SNAPSHOT } $self->disk_snapshot_names("$domain-qcow2") ) ? 1 : 0;
}

=head2 $hv->rebuild_destroys_guest($domain, capacity =E<gt> $bytes)

Returns 1 if a rebuild of this domain takes the guest apart, and 0 if not.

The answer is 1 when the guest exists and its disk cannot be kept at
C<capacity>.  C<clear_guest> then undefines the domain and deletes the disk.  A
first build, and a rebuild that can keep the disk, give 0.

This is not the opposite of C<rollback_possible>.  A reusable disk with no
C<trog-pristine> snapshot gives 0 from both, and the rebuild deletes that disk
without asking.  Many guests have such a disk, too many to stop the rebuild for.

=cut

sub rebuild_destroys_guest {
    my ( $self, $domain, %opts ) = @_;

    return 0 unless $self->domain_exists($domain);
    return $self->disk_reusable( $domain, $opts{capacity} ) ? 0 : 1;
}

=head2 $hv->clone_guest_disk($domain)

Copies the disk of this guest to the volume C<$domain.bak-qcow2>, and returns
the path of the copy.  If that volume already exists, this keeps it and returns
its path.

It stops the guest first, because a copy of a qcow2 that qemu is writing to is
not consistent.  The copy is only a volume, with no domain, no address and no
backing store.  So it cannot boot, and it does not need the base image.

Nothing removes the copy later, because C<guest_volumes> does not name it.

Returns undef when there is no disk to copy.  Dies if the copy fails, because
the caller rebuilds over the disk when this returns.

=cut

sub clone_guest_disk {
    my ( $self, $domain ) = @_;

    my $source = $self->volume("$domain-qcow2") or return;
    my $info   = $source->get_info();
    my $name   = "$domain$BACKUP_SUFFIX";

    if ( my $existing = $self->volume_path($name) ) {
        print "$name is in the pool already; keeping that rather than writing over it.\n";
        return $existing;
    }

    $self->stop_domain($domain);

    print "Copying $domain's disk aside as $name\n";

    my $clone = $self->pool->clone_volume( <<"XML", $source );
<volume>
  <name>@{[ xml_escape($name) ]}</name>
  <capacity unit='bytes'>$info->{capacity}</capacity>
  <target><format type='qcow2'/></target>
</volume>
XML

    return $clone->get_path();
}

=head2 $hv->backup_volumes

The names of all volumes in the pool that C<clone_guest_disk> made, sorted.
Dies if libvirt cannot list the pool.

Only this backend knows the suffix of a copy.  So a caller asks for this list
and does not match names itself.

=cut

sub backup_volumes {
    my ($self) = @_;

    # No eval, also around the volume names.  An empty list after EPERM makes a
    # caller remove fewer copies than exist.  list_all_volumes, not list_volumes,
    # which makes one RPC for each volume.
    my @names = sort grep { m/\Q$BACKUP_SUFFIX\E \z/ } map { $_->get_name() } $self->pool->list_all_volumes();

    return @names;
}

=head2 $hv->disk_owner_runs(@argv), $hv->disk_owner_says($cmd)

Run a command as the user that owns the disks of the pool, and return its exit
code, or what it printed.  That is root on the system URI, because libvirt gives
a disk to C<libvirt-qemu> when the guest starts.  On a session URI it is the
user of the URI, because its qemu runs as that user, and the disks stay its own.
C<$cmd> is a string for a shell, as C<capture_cmd> takes.

=cut

sub disk_owner_runs ( $self, @argv ) {
    return $self->is_session ? $self->run_cmd(@argv) : $self->run_sudo(@argv);
}

sub disk_owner_says ( $self, $cmd ) {
    return $self->capture_cmd( $self->is_session ? $cmd : "sudo -n $cmd" );
}

=head2 $hv->disk_layout($volume)

The layout of an existing qcow2 volume, as a hashref with C<cluster_size> in
bytes and C<extended_l2> as 1 or 0.  Undef when there is no such volume or
qemu-img does not answer.

=cut

sub disk_layout {
    my ( $self, $name ) = @_;

    # As the owner of the disk, -U, and no 2>/dev/null.  The guest can be
    # running, and its qemu holds a write lock, so qemu-img also needs -U.
    # Either failure returns undef, which disk_reusable reads as a disk that
    # cannot be kept.  So the errors stay visible.
    my $path = $self->volume_path($name) or return undef;
    my $json = $self->disk_owner_says("qemu-img info -U --output=json '$path'") // q{};
    my $info = eval { Cpanel::JSON::XS::decode_json($json) } or return undef;

    my $format = $info->{'format-specific'}{data} // {};
    return {
        cluster_size => $info->{'cluster-size'} // 0,
        extended_l2  => $format->{'extended-l2'} ? 1 : 0,
    };
}

=head2 $hv->snapshot_disk($volume, $name)

Takes an internal qcow2 snapshot C<$name> of a volume, with no domain.  Returns
1 if qemu-img took it, and 0 if not.  Dies if there is no such volume.

C<create_snapshot> asks libvirt to take a snapshot of a domain.  This asks
qemu-img to take one of the file.  So it works before the domain exists, which
is when C<create_disk> takes C<trog-pristine>.

=cut

sub snapshot_disk {
    my ( $self, $name, $snapname ) = @_;

    my $path = $self->volume_path($name) or die "There is no volume $name on " . $self->describe . " to snapshot\n";

    return $self->disk_owner_runs( qw{qemu-img snapshot -c}, $snapname, $path ) == 0 ? 1 : 0;
}

=head2 $hv->revert_disk($volume, $name)

Reverts a volume to its internal snapshot C<$name>.  Returns 1 if qemu-img
reverted it, and 0 if not.  Dies if there is no such volume.

The domain must not be running.  qemu-img writes the file directly, and the
image gets corrupted if qemu has it open.

This does not use the C<-U> of C<disk_layout> and C<disk_snapshot_names>.  That
flag goes past the write lock of qemu.  That is safe for a read of the disk of a
running guest, but not for a write.  C<snapshot_disk> also needs no C<-U>,
because it runs before the domain exists.

After a revert, every other snapshot is still listed and can still be reverted
to, and the backing file stays.  The rebuild that keeps a disk depends on this.

=cut

sub revert_disk {
    my ( $self, $name, $snapname ) = @_;

    my $path = $self->volume_path($name) or die "There is no volume $name on " . $self->describe . " to revert\n";

    # A revert that fails without a word leaves the new guest on the
    # filesystem of the old one.
    return $self->disk_owner_runs( qw{qemu-img snapshot -a}, $snapname, $path ) == 0 ? 1 : 0;
}

=head2 $hv->disk_snapshot_names($volume)

The names of all internal snapshots in a volume, in the order that qemu-img
lists them.  An empty list when there is no such volume or no snapshot.

=cut

sub disk_snapshot_names {
    my ( $self, $name ) = @_;

    # -U, for the reason that disk_layout gives.  rollback_possible asks this
    # about a running guest.  If qemu-img cannot open the disk, the answer is
    # "no snapshots", and no rollback happens.
    my $path = $self->volume_path($name) or return ();
    my $said = $self->disk_owner_says("qemu-img snapshot -l -U '$path'") // q{};

    # After the header, each line starts with a numeric id, and the tag is the
    # second field.
    return map { ( split q{ }, $_ )[1] } grep { m/\A \s* \d+ \s+ \S/ } split m/\n/, $said;
}

=head2 lease_nic

The bridge of the adapter whose lease this machine reaches a guest by: the
first of C<dhcp_nics> in the block, or else the bridge of the C<default>
network, whose leases L</lease_ip($network, %opts)> reads.  It asks libvirt for
that through L</network_vmm>, and dies when it finds nothing.

=head2 virbr_ip

The address of the hypervisor on L</lease_nic>.  The guest fetches its files
from this address and sends its logs to it.  It reads C<ip> on the hypervisor,
and dies when that finds nothing.

=cut

sub lease_nic {
    my ($self)  = @_;
    my ($first) = $self->setting_list('dhcp_nics');
    return $first             if defined $first;
    return $self->{lease_nic} if defined $self->{lease_nic};

    my $device = eval { $self->network_vmm->get_network_by_name('default')->get_bridge_name };
    die "Could not determine libvirt network device on " . $self->uri . "!\n" . "Set dhcp_nics in this hypervisor's block of hypervisors.conf, or in provision.conf if there is no hypervisors.conf.\n"
      unless $device;

    return $self->{lease_nic} = $device;
}

sub virbr_ip {
    my ($self) = @_;
    return $self->{virbr_ip} if defined $self->{virbr_ip};

    my $device = $self->lease_nic;
    my $ip     = $self->capture_cmd("ip addr show dev $device | grep inet | head -n1 | awk '{print \$2}'");
    die "Could not determine IP address for $device\n" unless $ip;
    chomp $ip;
    $ip =~ s{/\d+\z}{};

    return $self->{virbr_ip} = $ip;
}

=head1 GUEST NETWORKS

A guest can have adapters on libvirt networks other than C<default>: see
L</ADAPTERS>.  F<bin/guest_network> makes such a network through
C<guest_network_steps>.  The preflight checks C<check_guest_bridges>,
C<check_guest_networks>, C<check_bridge_acl> and C<check_guest_pool> ask
whether each bridge of a guest is there, up and allowed, and whether the pool
of the guests is on the network of its bridge.  They only read.

=cut

# The name of a network in libvirt, as guest_network_plan takes it.
my $NETWORK_NAME = qr/\A [[:alnum:]] [[:alnum:]_.-]{0,49} \z/;

# The blocks and addresses of $pool, a nic_pool, that are not inside the
# block $cidr.
my sub outside_of ( $cidr, $pool ) {
    my $network = Net::IP->new($cidr);
    return grep {
        my $item = Net::IP->new($_);
        my $how  = $item ? $item->overlaps($network) // 0 : 0;
        $how != $Net::IP::IP_A_IN_B_OVERLAP && $how != $Net::IP::IP_IDENTICAL;
    } @{ $pool->{cidr} // [] }, map { s{/\d+\z}{}r } @{ $pool->{addresses} // [] };
}

# The attributes of an element, from the text of its start tag.
my sub attributes ($tag) {
    my %attribute;
    while ( $tag =~ m{([\w-]+) \s* = \s* (['"]) (.*?) \2}g ) {
        $attribute{$1} = $3;
    }
    return \%attribute;
}

# What the XML of a libvirt network says about the guests on it: bridge, the
# name of its bridge; forward, its forward mode, or none for an isolated
# network; address, the address of the host on it, and cidr, its block, from
# the first IPv4 address; and leases, the blocks of every DHCP range.  A key
# that the XML does not give is left out.
my sub network_facts ($xml) {
    my %facts = ( leases => [] );

    my ($bridge) = $xml =~ m{(<bridge\b[^>]*>)};
    $facts{bridge} = attributes($bridge)->{name} if $bridge;

    # A forward element with no mode is NAT, and no forward element at all is
    # an isolated network.
    my ($forward) = $xml =~ m{(<forward\b[^>]*>)};
    $facts{forward} = $forward ? attributes($forward)->{mode} // 'nat' : 'none';

    my ($ip) = grep { ( $_->{family} // 'ipv4' ) eq 'ipv4' && defined $_->{address} } map { attributes($_) } $xml =~ m{(<ip\b[^>]*>)}g;
    if ($ip) {
        $facts{address} = $ip->{address};
        $facts{cidr}    = defined $ip->{prefix} ? Trog::HV::network_of( $ip->{address}, $ip->{prefix} ) : eval { Net::CIDR::addrandmask2cidr( $ip->{address}, $ip->{netmask} ) };
    }

    $facts{leases} = [ map { Net::CIDR::range2cidr("$_->{start}-$_->{end}") } grep { defined $_->{start} && defined $_->{end} } map { attributes($_) } $xml =~ m{(<range\b[^>]*>)}g ];
    return \%facts;
}

# The network of the system daemon whose bridge is $bridge, or undef.  A
# network with no bridge, such as one of macvtap, has no bridge name to give.
my sub network_on ( $self, $bridge ) {
    return List::Util::first {
        ( eval { $_->get_bridge_name } // q{} ) eq $bridge
    }
    $self->network_vmm->list_all_networks;
}

=head2 \%plan = Trog::HV::Libvirt->guest_network_plan(%args)

The network that C<guest_network_steps> makes, from these arguments:

=over 4

=item C<name>

The name of the network in libvirt: a letter or a digit, then up to 49 letters,
digits, C<_>, C<.> and C<->.

=item C<bridge>

Its bridge, a name that the kernel takes for a link.

=item C<address>

The IPv4 address of the hypervisor on it, which is the gateway of its guests.

=item C<prefix>

The length of its prefix, from 8 to 30.

=item C<pool>

The pool of its static adapter, as L<Trog::HV/nic_pool($nic)> gives it.  Optional.

=back

Returns them, with C<cidr>, the block of the network.  Dies with the reason on
a value that is not one of these, on an address that is the address of the
block itself, and on an address or a block of the pool that is not inside the
network, because a guest with that address could not reach its gateway.

=cut

sub guest_network_plan ( $, %args ) {
    my %plan = %args{qw{name bridge address prefix}};
    $plan{$_} //= q{} for keys %plan;

    die "The name of a guest network in libvirt is a letter or a digit, then letters, digits, _, . and -, and '$plan{name}' is not\n" unless $plan{name}   =~ $NETWORK_NAME;
    die "The bridge of a guest network is the name of a link, and '$plan{bridge}' is not\n"                                           unless $plan{bridge} =~ $Trog::Patterns::LINK_NAME;

    my $ip = Net::IP->new( $plan{address} );
    die "The address of the hypervisor on a guest network is an IPv4 address, and '$plan{address}' is not\n" unless $ip && $ip->version == 4 && $ip->size == 1;
    die "The prefix of a guest network is a number from 8 to 30, and '$plan{prefix}' is not\n"               unless Trog::HV::is_prefix_length( $plan{prefix} );

    $plan{cidr} = Trog::HV::network_of( $plan{address}, $plan{prefix} );
    die "$plan{address} is the address of the block $plan{cidr} itself, which no host on it can have\n" if index( $plan{cidr}, "$plan{address}/" ) == 0;

    my @outside = outside_of( $plan{cidr}, $args{pool} // {} );
    die 'The pool of the guests has ' . join( ', ', @outside ) . " outside $plan{cidr}, so a guest with one of those addresses could not reach its gateway $plan{address}\n" if @outside;

    return \%plan;
}

=head2 $xml = Trog::HV::Libvirt->guest_network_xml(\%plan, $uuid)

The libvirt XML of the network of C<\%plan>.  It forwards by NAT to the networks
of the host, on the bridge of the plan, with the address of the plan.  It has no
DHCP, because each guest on it has a static address from the pool, which its
network configuration gives it.

With C<$uuid>, the XML keeps the uuid of the network that it defines again,
because libvirt refuses a definition under a name that it knows with another
uuid.

With C<forward mode='nat'>, libvirt lets a guest on the network start a
connection out, and refuses a new connection in from outside the host.  So this
machine still reaches a guest by the lease of its NAT adapter.  "The adapters
of a guest" in F<docs/CONFIGURATION.md> says when to make a network with
C<mode='route'> instead, by hand.

=cut

sub guest_network_xml ( $, $plan, $uuid = undef ) {
    return join "\n", '<network>', "  <name>$plan->{name}</name>", ( defined $uuid ? "  <uuid>$uuid</uuid>" : () ), "  <forward mode='nat'/>", "  <bridge name='$plan->{bridge}' stp='on' delay='0'/>", "  <ip address='$plan->{address}' prefix='$plan->{prefix}'/>", '</network>', q{};
}

=head2 @actions = $hv->guest_network_steps(\%plan)

The actions that make the network of C<\%plan> on the system daemon of this
hypervisor, for L<Trog::Steps/run>, in order:

=over 4

=item 1. Define it, persistent, unless it is defined already with the bridge,
the forward mode, the address and the prefix of the plan, and no DHCP.  A
network with that name and other values is defined again with the values of the
plan, under its own uuid.  If it is running, it keeps what it had until it
restarts, and the action prints how to restart it, because a restart takes the
link away from each guest on it.

=item 2. Start it.

=item 3. Start it with the host.

=back

Before the first, it dies when this hypervisor is a session, because nothing
outside a session can join one of its networks, and when another network has
the bridge of the plan.

=cut

sub guest_network_steps ( $hv, $plan ) {
    die 'A guest network belongs to the system daemon, and ' . $hv->describe . " is a session.  Name the block of an account on the system URI of the same host, as bin/guest_network --via does.\n"
      if $hv->is_session;

    my $vmm  = $hv->vmm;
    my $name = $plan->{name};

    my $other = network_on( $hv, $plan->{bridge} );
    die "The bridge $plan->{bridge} on " . $hv->describe . ' belongs to the network ' . $other->get_name . ", so the network $name cannot have it\n"
      if $other && $other->get_name ne $name;

    my $network = sub {
        return eval { $vmm->get_network_by_name($name) } || undef;
    };
    my $restart = join q{ }, 'virsh -c', $hv->uri, "net-destroy $name &&", 'virsh -c', $hv->uri, "net-start $name";

    return (
        {
            what => "define the network $name, NAT on $plan->{bridge} at $plan->{address}/$plan->{prefix}, with no DHCP",
            done => sub {
                my $net  = $network->();
                my $has  = $net ? network_facts( $net->get_xml_description( Sys::Virt::Network::XML_INACTIVE() ) ) : {};
                my %want = ( %$plan, forward => 'nat' );
                return ( List::Util::all { ( $has->{$_} // q{} ) eq $want{$_} } qw{bridge forward address cidr} ) && !@{ $has->{leases} // [] };
            },
            do => sub {
                my $old = $network->();
                $vmm->define_network( Trog::HV::Libvirt->guest_network_xml( $plan, $old ? $old->get_uuid_string : undef ) );
                print "        It runs with what it had until it restarts, which takes the link from each guest on it:\n" . "        $restart\n" if $old && $old->is_active;
            },
        },
        {
            what => "start the network $name",
            done => sub { my $net = $network->(); $net && $net->is_active },
            do   => sub { $network->()->create },
        },
        {
            what => "start the network $name with the host",
            done => sub { my $net = $network->(); $net && $net->get_autostart },
            do   => sub { $network->()->set_autostart(1) },
        },
    );
}

=head2 %adapters = $hv->runner_adapters(\%block, $user)

The adapters of the guests of the runner C<$user>, from C<\%block>, the block of
the runner as L<Provisioner::Recipe::trogrunner> takes it, on the same host as
this hypervisor, which acts for it:

=over 4

=item C<bridges>

A reference to the list of its bridges: its C<dhcp_nics>, or the bridge of the
C<default> network of this hypervisor when it names none, and then its
C<static_nics>.  It is what the account of the runner may join.

=item C<networks>

A reference to a list of plans from C<guest_network_plan>, one for each of its
C<static_nics>, with the gateway, the prefix and the pool of the block.  Each
network is named C<USER-BRIDGE>.

=back

Dies as the block of the runner would, on an adapter without a pool or a
gateway, and as C<guest_network_plan> does.

=cut

sub runner_adapters ( $hv, $block, $user ) {
    my $class  = ref $hv;
    my $runner = $class->candidate( $class->options_from_block($block) );

    my @dhcp     = $runner->setting_list('dhcp_nics');
    my @static   = $runner->static_nics;
    my @networks = map {
        $class->guest_network_plan(
            name    => "$user-$_",
            bridge  => $_,
            address => $runner->nic_gateway($_),
            prefix  => $runner->nic_prefix_length($_),
            pool    => $runner->nic_pool($_),
        )
    } @static;

    return ( bridges => [ ( @dhcp ? @dhcp : $hv->lease_nic ), @static ], networks => \@networks );
}

=head2 @actions = $hv->runner_network_steps(\%plan)

The actions that give a static adapter of the guests of a runner its network,
on the system daemon of this hypervisor.  C<\%plan> is from
C<guest_network_plan>, for a bridge of the C<static_nics> of the block of the
runner.

When the bridge is a bridge of the host that no network of libvirt owns, such
as one that bridges the LAN, it is not this software's to make.  Then the one
action says so and changes nothing.  Otherwise the actions are those of
C<guest_network_steps>.  L<Provisioner::Recipe::trogrunner> runs these when it
provisions a runner with an account.

=cut

sub runner_network_steps ( $hv, $plan ) {
    my $bridge = $plan->{bridge};
    return {
        what => "leave $bridge to " . $hv->describe . ', which has it as a bridge of its own',
        done => sub { 1 },
        do   => sub { },
      }
      if !network_on( $hv, $bridge ) && $hv->run_cmd( qw{test -d}, "/sys/class/net/$bridge/bridge" ) == 0;
    return $hv->guest_network_steps($plan);
}

=head2 @actions = $hv->runner_network_removal_steps(\%plan, $user)

The action that undoes C<runner_network_steps> when the runner C<$user> goes:
the network of C<\%plan> is stopped and undefined.  It stays when it has
another bridge than the plan, because then this software did not make it.  It
also stays while a guest of the system daemon is on it, while the file of
another runner account lets that account join its bridge, and while the file of
C<$user> is there.  That file goes with the account, which does not go while its
pool holds the disk of a guest, so a network stays under the guests of a runner
that could not be taken away.  Then the action says
why and changes nothing.

=cut

sub runner_network_removal_steps ( $hv, $plan, $user ) {
    my ( $name, $bridge ) = @{$plan}{qw{name bridge}};
    my $network = sub {
        my $net = eval { $hv->vmm->get_network_by_name($name) } || return undef;
        return ( eval { $net->get_bridge_name } // q{} ) eq $bridge ? $net : undef;
    };

    # The guests of the system daemon on it, which libvirt counts in the XML of a
    # network that runs, the runner if its account is still there, and the other
    # accounts that may put theirs on it.
    my $users = sub ($net) {
        my ($guests) = $net->is_active ? $net->get_xml_description =~ m/<network\b[^>]*\bconnections=['"](\d+)['"]/ : ();
        my $own = Trog::HV::Libvirt::BridgeHelper::acl_file($user);
        return ( $guests ? "$guests guest(s) of the system daemon" : () ), ( $hv->file_exists($own) ? "the account $user, whose $own is still there" : () ),
          Trog::HV::Libvirt::BridgeHelper::allowed_by_others( $hv, $bridge, $user );
    };

    return {
        what => "remove the network $name, unless something else still joins $bridge",
        done => sub { !$network->() },
        do   => sub {
            my $net  = $network->();
            my @busy = $users->($net);
            return print "        It stays, because these still join $bridge: " . join( ', ', @busy ) . "\n" if @busy;
            $net->destroy                                                                                    if $net->is_active;
            $net->undefine;
        },
    };
}

=head1 CAPACITY

What the hypervisor has and what its guests already have.  L<Trog::HV> uses
this to decide if one more guest fits.  All of it comes from libvirt, not from a
configuration file.

Memory counts as I<committed>, not I<used>.  A guest with 8G holds 8G, also when
it uses only 400M.  If the guests have more memory than the host, the OOM killer
eventually stops a guest.  More vCPUs than CPUs is normal.  So the CPU limit is C<cpu_overcommit>
times the number of physical CPUs.

=head2 capacity

The state of the hypervisor, as a hashref.  The first call reads it, and later
calls return the same one:

    memory_mb        physical memory
    memory_committed committed to guests, running or not
    memory_free      what is left after the reserve
    cpus             physical CPUs
    cpus_allocatable cpus * cpu_overcommit
    cpus_committed   vCPUs handed to running guests
    cpus_free        what is left after the reserve
    disk_free        free bytes in the storage pool, after the reserve
    guests           how many domains it knows about

With a L</partition>, the CPU keys and C<guests> are those of the partition, and
C<partition> names it.  A domain is in the partition that its definition names
in C<< <resource><partition> >>, and a domain that names none is in
C</machine>, the default of libvirt.  Then:

    cpus             the CPUQuota of the slice of the partition in cores,
                     or the physical CPUs when it has none, whichever is less
    cpus_allocatable cpus * cpu_overcommit
    cpus_committed   vCPUs handed to running guests of the partition
    cpus_free        allocatable less committed, with no reserve
    guests           how many domains of the partition it knows about
    host             the CPU keys and guests above, for the whole hypervisor

The reserve is for the host, so only C<host> takes it off.  The quota is what
the guests of the partition can use, so it is what their vCPUs overcommit.
L<Trog::HV/shortfalls(%needs)> refuses a guest when either the partition or the
host has no room.  So a runner with a partition of its own cannot fill the
hypervisor for the guests outside it.  The disk stays as it is, because it is
already that of the pool.

On a session URI, the guests of the session are the share, as the guests of a
partition are.  Their slice is the user slice of the account,
F<user-UID.slice>, and C<partition> names that slice.  The host is the guests
of the session and the guests of the system daemon, which L</network_vmm>
lists.  The guests in the session of another user are not in it, because no
connection of this user can see them.

Memory stays that of the host, unless the block gives the partition a
L</max_memory>.  Then the memory keys are those of the partition, and C<host>
has the memory keys of the whole hypervisor as well:

    memory_mb        max_memory, or the physical memory, whichever is less
    memory_committed committed to guests of the partition, running or not
    memory_free      max_memory less committed, with no reserve

So a guest must fit in the budget of the partition and in the memory of the
host, after its reserve.  The memory of the host is shared whoever holds it, so
a partition with no budget is held to the host alone.

Dies if libvirt does not answer, because a guest must not go on a hypervisor
that cannot give these values.

=cut

sub capacity {
    my ($self) = @_;
    return $self->{capacity} if $self->{capacity};

    my $node = $self->vmm->get_node_info();

    # Each domain, and whether it is in the share.  Every domain of a session
    # is, and no domain of the system daemon beside it is.
    my $session = $self->is_session;
    my @domains = map { [ $_, $session ] } $self->vmm->list_all_domains();
    push @domains, map { [ $_, 0 ] } $self->network_vmm->list_all_domains() if $session;

    my $partition = $self->partition;
    my $slice     = $session ? $self->session_slice : defined $partition ? partition_slice($partition) : undef;

    my ( $memory_committed, $cpus_committed, $ours, $our_cpus, $our_memory ) = ( 0, 0, 0, 0, 0 );
    foreach my $entry (@domains) {
        my ( $domain, $in_session ) = @$entry;
        my $info = eval { $domain->get_info() } or next;

        my $vcpus = eval { $domain->is_active() } ? $info->{nrVirtCpu} // 0 : 0;
        $cpus_committed += $vcpus;

        # maxMem is the most memory the guest can use, so it counts in full.
        my $memory = ( $info->{maxMem} // 0 ) / $Provisioner::Vars::KB;
        $memory_committed += $memory;

        next unless defined $slice;
        if ( !$in_session ) {
            next if $session;
            my $xml = eval { $domain->get_xml_description() } // q{};
            my ($in) = $xml =~ m{<partition>\s*([^<\s]+)\s*</partition>};
            next unless ( $in // '/machine' ) eq $partition;
        }
        $ours++;
        $our_cpus   += $vcpus;
        $our_memory += $memory;
    }

    my $memory_mb        = ( $node->{memory} // 0 ) / $Provisioner::Vars::KB;
    my $cpus             = $node->{cpus} // 0;
    my $cpus_allocatable = $cpus * $self->cpu_overcommit;

    my %host = (
        cpus             => $cpus,
        cpus_allocatable => $cpus_allocatable,
        cpus_committed   => $cpus_committed,
        cpus_free        => $cpus_allocatable - $cpus_committed - $self->reserve_cpus,
        guests           => scalar @domains,
    );
    my %memory = (
        memory_mb        => $memory_mb,
        memory_committed => $memory_committed,
        memory_free      => $memory_mb - $memory_committed - $self->reserve_memory,
    );

    my %cpus = %host;
    if ( defined $slice ) {
        if ( $self->max_memory ) {
            my $budget = $self->max_memory < $memory_mb ? $self->max_memory : $memory_mb;
            %host   = ( %host, %memory );
            %memory = (
                memory_mb        => $budget,
                memory_committed => $our_memory,
                memory_free      => $budget - $our_memory,
            );
        }

        my $quota = $self->slice_cpu_quota($slice);
        my $share = defined $quota && $quota < $cpus ? $quota : $cpus;
        my $total = int( $share * $self->cpu_overcommit );
        %cpus = (
            cpus             => $share,
            cpus_allocatable => $total,
            cpus_committed   => $our_cpus,
            cpus_free        => $total - $our_cpus,
            guests           => $ours,
            partition        => $partition // $slice,
            host             => \%host,
        );
    }

    return $self->{capacity} = {
        %memory,
        disk_free => $self->pool_free() - $self->reserve_disk,
        %cpus,
    };
}

=head2 pool_free($name)

The free bytes in the storage pool C<$name>, or 0 when there is no such pool.
C<$name> defaults to L</pool_name>.

=cut

sub pool_free {
    my ( $self, $name ) = @_;
    $name //= $self->pool_name;

    my $vmm  = $self->vmm;
    my $pool = eval { $vmm->get_storage_pool_by_name($name) } or return 0;
    my $info = eval { $pool->get_info() }                     or return 0;
    return $info->{available} // 0;
}

=head1 PROVISIONING

=head2 prepare_host($virtiofs)

Makes the directory of the storage pool, and installs C<$virtiofs> as
F</usr/libexec/virtiofs-better> if it is not there.  That program runs in the
qemu process, so it must be on the hypervisor.  Returns 1.  Dies if either step
fails.

On a session URI it does not install the program, because a guest there has no
virtiofs share: see L<Provisioner::Recipe::vm/enrich>.

=cut

sub prepare_host {
    my ( $self, $virtiofs ) = @_;

    $self->mkpath( $self->pool_path )
      or die "Could not create storage pool dir " . $self->pool_path . " on the hypervisor";

    return 1 if $self->is_session || $self->file_exists('/usr/libexec/virtiofs-better');

    $self->put_file( $virtiofs, '/usr/libexec/virtiofs-better', sudo => 1 )
      or die('Could not copy virtiofs-better to /usr/libexec/virtiofs-better, you may have to do this manually');
    $self->run_sudo(qw{chmod 0755 /usr/libexec/virtiofs-better});

    return 1;
}

=head2 release_seed($domain)

Removes the cloud-init ISO from the guest.  See
L</eject_cdrom($domain, $target)>, which also says why this waits for cloud-init.

=head2 guest_volumes($domain)

The names of the overlay disk and the seed ISO of the guest, for those that
exist.

=cut

sub release_seed ( $self, $domain ) { return $self->eject_cdrom($domain) }

sub guest_volumes {
    my ( $self, $domain ) = @_;
    return grep { $self->volume($_) } ( "$domain-qcow2", "$domain-cloudinit.iso" );
}

=head2 guest_ssh_ip($config, $lease_ip)

The address that I<this machine> uses to SSH into a guest.

On a local hypervisor, that is C<$lease_ip>, the libvirt NAT lease.  On a remote
hypervisor, the NAT lease usually routes only from the hypervisor.  So the
result is the first address in C<ips> in the configuration, the bridged static
address of the guest.

A guest with no C<ips> has only its lease, which
L<Provisioner::IPPool/offers> explains.  This machine reaches that lease when
it is a guest of the same hypervisor, on the same NAT network: see
C<on_nat_network>.  Then the result is C<$lease_ip>.  Dies if neither is so.

=cut

sub guest_ssh_ip {
    my ( $self, $config, $lease_ip ) = @_;
    return $lease_ip if $self->is_local;

    my ($ip) = grep { $_ } $config->param('ips');
    return $ip       if $ip;
    return $lease_ip if $lease_ip && $self->on_nat_network;

    die "Provisioning against a remote hypervisor (" . $self->uri . ") requires the guest to have a\n" . "routable address: set 'ips' in provision.conf, or run this from a guest of that hypervisor on its NAT network.\n" . "The libvirt NAT lease (" . ( $lease_ip // 'none' ) . ") is reachable only from the hypervisor and from its other guests.\n";
}

=head2 $bool = on_nat_network()

Whether this machine is on the NAT network of the hypervisor, so that it reaches
the lease of a guest there directly.

It is, when the hypervisor leased it one of the addresses that it holds.  That
is the case of a runner that is itself a guest of the hypervisor.  The subnet
alone does not answer this.  The C<default> network of libvirt has the same
block on every host that does not change it, so a machine on that network of one
hypervisor is in the subnet of the others too, and reaches none of their guests.

Always true on a local hypervisor.  It asks once, and remembers the answer.

=cut

sub on_nat_network {
    my ($self) = @_;
    return 1 if $self->is_local;

    $self->{on_nat_network} //= ( List::Util::any { Trog::Local->holds_address($_) } $self->lease_ips('default') ) ? 1 : 0;
    return $self->{on_nat_network};
}

=head2 $address = nat_address($domain)

The NAT lease of the guest of C<$domain>, when this machine reaches it, as
C<on_nat_network> says.  Undef when the guest holds no lease, or when this
machine cannot reach it.

A guest that got no address from the pool has no other address, and this is how
C<bin/new_config> finds it again to salvage it before a rebuild.

=cut

sub nat_address {
    my ( $self, $domain ) = @_;
    return $self->on_nat_network ? $self->inspection_address($domain) : undef;
}

=head2 image_for_distro($distro, $release)

The distro's C<base_image> for C<$release>: a URL, which C<base_image> here
downloads into the pool.

=cut

sub image_for_distro ( $, $distro, $release = undef ) { return $distro->base_image($release) }

=head2 inspection_address($domain)

The NAT lease of the guest's first interface, or undef when it holds none.  The
guest answers there whether or not its static address ever came up, which is
the case that matters when something went wrong.

=cut

sub inspection_address {
    my ( $self, $domain ) = @_;
    return $self->lease_ip( 'default', mac => $self->guest_mac( $domain, 0 ) );
}

=head2 @names = $hv->preflight_checks(), $hv->preflight_notes()

The names of the checks and notes that C<bin/preflight> runs on this backend, in
order.  L<Trog::HV/PREFLIGHT> describes what each one returns.

=cut

sub preflight_checks { return qw{check_client check_reachable check_passwordless_sudo check_iso_builder check_rsync check_sandbox check_gpg check_transfer_ip check_transfer_route check_fetch_sources check_libvirt check_sys_virt_in_step check_guest_bridges check_guest_networks check_bridge_acl check_guest_pool check_pool_writable check_config} }
sub preflight_notes  { return qw{note_libguestfs note_swtpm note_stale_image note_apt_mirror note_log_destination note_pool_quota note_plaintext_secrets} }

=head2 $result = $hv->check_reachable()

Passes on a local hypervisor, or when C<whoami> runs over ssh on a remote one.

=cut

sub check_reachable {
    my ($self) = @_;

    return $self->verdict( 1, 'The hypervisor is this machine', q{} ) if $self->is_local;

    my $whoami = eval { $self->capture_cmd('whoami') };
    chomp $whoami if defined $whoami;

    return $self->verdict( 1, "Reached " . $self->ssh_target . " as $whoami", q{} )
      if $whoami;

    return $self->verdict( 0, 'Cannot reach ' . $self->describe, <<"FIX" );
ssh -v @{[ $self->ssh_target ]} and see what it says.  This wants an agent or a
key already trusted there; nothing here can answer a password prompt.
FIX
}

=head2 $result = $hv->check_transfer_ip()

Passes when this machine has an address that a guest on the NAT bridge can
fetch its payload from, over ssh.  Without one, the run fails at the first
target on the guest, so this asks first.

It asks the routing table, which cannot see a firewall or a route that works in
one direction only.  So a pass means that there is an address to try, not that
the guest can reach it.

=cut

sub check_transfer_ip {
    my ($self) = @_;

    my $virbr = eval { $self->virbr_ip };
    return $self->verdict( 0, 'Could not ask the hypervisor for its NAT bridge', <<"FIX" ) unless $virbr;
$@
Guests are built on that network and fetch their payload across it, so this has
to answer before anything can be worked out about reaching them.
FIX

    my $ours = eval { Trog::Local->new()->transfer_ip($virbr) };
    return $self->verdict( 1, "Guests fetch their payload from $ours", q{} ) if $ours;

    return $self->verdict( 0, "No address of ours is reachable from a guest on $virbr", <<"FIX" );
A guest scps its payload and rsyncs its data directory out of this machine, so
it needs an address here that it can get to.  Nothing routes to the
hypervisor's guest network from here.

Put this machine on that network, or name the address yourself in the _global
of _base in recipes.yaml:

    transfer_ip: 192.0.2.10
FIX
}

=head2 $result = $hv->check_passwordless_sudo()

Passes when the ssh user has passwordless sudo, for everything or only for the
lease helper.  Fails, with the commands that give the grant, when it has neither.

A grant for the lease helper alone is enough to build a guest.  On the system
URI, the other root steps are the first install of F<virtiofs-better> and the
C<qemu-img> calls for the C<trog-pristine> snapshot and its revert.  Without
those, a guest builds, but a rebuild cannot keep its disk.  On a session URI,
the account runs those as itself, so the grant of C<runner_sudoers> is all
that it needs.

C<sudo -n true> fails for the narrow grant, so this also asks C<sudo -n -l>
about the lease helper.  It asks with the arguments that
C<release_dhcp_lease> passes, because a grant that pins the arguments does not
match the helper alone.

=cut

# An address of TEST-NET-1, which no lease has.  sudo -l only says whether the
# command would be allowed, and runs nothing.
my $PROBE_LEASE = '192.0.2.1';

sub check_passwordless_sudo {
    my ($self) = @_;

    if ( $self->run_cmd(qw{sudo -n true}) == 0 ) {
        my $allowed = eval { $self->capture_cmd('sudo -n -l 2>/dev/null') } // q{};
        my $whole   = $allowed =~ m/NOPASSWD:\s*ALL/;

        return $self->verdict( 1, 'Passwordless sudo, for everything', q{} ) if $whole;
        return $self->verdict( 1, 'Passwordless sudo',                 q{} );
    }

    # A narrow grant is correct for an account that builds guests unattended.
    my $helper = $self->lease_helper // $LEASE_HELPERS[0];
    return $self->verdict( 1, "Passwordless sudo for $helper, which is what a provision needs", <<"FIX" )
On the system URI, a rebuild that keeps the disk of a guest also needs root for
qemu-img on the volumes of the pool.  An account of bin/runner_account builds
on its session URI, and needs only this.
FIX
      if $self->run_cmd( qw{sudo -n -l}, $helper, qw{del ip}, $PROBE_LEASE ) == 0;

    my $user   = $self->ssh_user // 'you';
    my $target = $self->is_local ? 'this machine' : $self->ssh_host;

    return $self->verdict( 0, "No passwordless sudo for $user on $target", <<"FIX" );
Provisioning writes to the storage pool and defines domains, all through
sudo.  A password prompt in the middle of that has nowhere to be answered
from, and the run hangs rather than failing.

On $target:

    echo '$user ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-$user
    sudo chmod 0440 /etc/sudoers.d/90-$user

Then check it took:

    ssh @{[ $self->ssh_target // $user ]} sudo -n true

This is a real grant of root on a hypervisor.  If that is not something you
want standing, make it, use it, and take it away again afterwards.

There is a narrower one that is enough to build guests with.  Everything else
a provision does is the libvirt API -- which wants group membership, not root
-- or a write into the storage pool.  For an account of its own, with a pool
that has a quota, run this from the machine that provisions:

    bin/runner_account --hypervisor <name> --user <account> \\
        --pool-name <pool> --pool-path <dir> --quota 500G

That needs /usr/libexec/virtiofs-better already in place -- bin/provision
installs it on first use, which is the one step that wants the wider grant.
FIX
}

=head2 $result = $hv->check_pool_writable()

Passes when the ssh user can write a file to the storage pool directory.

It runs after C<check_libvirt>, because C<pool_path> can need libvirt to find
the pool.

All other checks can pass while the hypervisor still cannot build a guest.
C<base_image> downloads into this directory without sudo.  So a pool that the
run cannot write to fails minutes into a provision, with an error about the URL
and not the permissions.  C<pool_takes_direct_io> also writes here, and gives a
wrong answer when the write itself is refused.

=cut

sub check_pool_writable {
    my ($self) = @_;

    my $path = eval { $self->pool_path };
    return $self->verdict( 0, 'Could not work out where the storage pool is', <<'FIX' ) unless $path;
libvirt looks a pool up by name, so pool_name in hypervisors.conf has to name one
this hypervisor has, or pool_path has to say outright where it is:

    virsh pool-list --all
FIX

    # The probe of pool_takes_direct_io, without O_DIRECT.
    my $probe = "$path/.writable-probe.$$";
    return $self->verdict( 1, "Storage pool $path takes a write", q{} )
      if $self->run_cmd( 'sh', '-c', 'touch "$1" 2>/dev/null && rm -f "$1"', 'sh', $probe ) == 0;

    return $self->verdict( 0, "Storage pool $path is not writable on " . $self->describe, <<"FIX" );
The base image is downloaded into the pool with a plain curl, on purpose: a pool
directory this run cannot write to is one no guest could ever have been built
from, so sudo here would paper over the misconfiguration rather than fix it.

    sudo chown \$USER:adm $path
    sudo chmod 0775 $path

A pool built by libvirt takes its ownership from the pool definition rather than
from the filesystem, so set it there too or the next pool-build puts it back:

    virsh pool-dumpxml <pool>    # the <permissions> under <target>
FIX
}

=head2 $result = $hv->check_iso_builder()

Passes when the hypervisor has a program that makes the seed ISO.  See
L</iso_maker>.

=cut

sub check_iso_builder {
    my ($self) = @_;

    my $maker = eval { $self->iso_maker };
    return $self->verdict( 1, "Cloud-init seed builder: $maker", q{} ) if $maker;

    return $self->verdict( 0, 'No ISO builder on the hypervisor', <<'FIX' );
cloud-init reads its configuration off a small ISO, and something has to make
it:

    sudo apt install xorriso
FIX
}

# Turns a packed libvirt version, major * 1000000 + minor * 1000 + release, into
# dotted form.  libvirt_version is a different method, which asks the connection.
my sub version_string ($packed) {
    return sprintf '%d.%d.%d', int( $packed / 1000000 ), int( $packed / 1000 ) % 1000, $packed % 1000;
}

=head2 $result = $hv->check_libvirt()

Passes when libvirt answers on the connection URI.

=cut

sub check_libvirt {
    my ($self) = @_;

    my $version = eval { $self->vmm->get_library_version() };
    return $self->verdict( 1, 'libvirt answers, running ' . version_string($version), q{} ) if $version;

    return $self->verdict( 0, 'libvirt did not answer', <<"FIX" );
$@
The URI is @{[ $self->uri ]}.  Check libvirtd is running there and that the user
is in the libvirt group, or, for a session URI, in the kvm group and lingering:
see runner_account_steps in Trog::HV::Libvirt.
FIX
}

=head2 $result = $hv->check_sys_virt_in_step()

Passes when the major and minor version of the local L<Sys::Virt> are the same
as those of libvirt on the hypervisor.

Each Sys::Virt release follows a libvirt release and binds its API.  With a
different libvirt, the error does not say "version mismatch".  It is a missing
constant or a call that the hypervisor does not implement, in an error about
some other operation.

=cut

sub check_sys_virt_in_step {
    my ($self) = @_;

    my $remote = eval { $self->vmm->get_library_version() };
    return $self->verdict( 0, 'Could not ask the hypervisor its libvirt version', <<'FIX' ) unless $remote;
libvirt did not answer, so this could not be checked.  Fix that first; the
answer is above.
FIX

    my $there = version_string($remote);
    my $here  = Sys::Virt->VERSION;

    my ($here_mm)  = $here  =~ m/\A(\d+\.\d+)/;
    my ($there_mm) = $there =~ m/\A(\d+\.\d+)/;

    return $self->verdict( 1, "Sys::Virt $here matches libvirt $there on the hypervisor", q{} )
      if defined $here_mm && defined $there_mm && $here_mm eq $there_mm;

    return $self->verdict( 0, "Sys::Virt $here here, libvirt $there on the hypervisor", <<"FIX" );
These want to be the same release.  Sys::Virt is versioned to track libvirt and
binds the API of the one it was built against, so a mismatch does not announce
itself -- it shows up as a missing constant or an unimplemented call, blamed on
whatever was being done at the time.

Either bring this machine to $there:

    apt-cache policy libvirt-dev    # what is available here
    cpanm Sys::Virt\@$there         # once libvirt-dev matches

or provision from a machine whose libvirt already does.  Installing a Sys::Virt
that does not match the local libvirt-dev will not build.

FIX
}

=head2 Checks of the bridges of the guests

The four checks below ask whether the guests of the block can have their
adapters: see L</ADAPTERS>.  They only read.  Each one fails with what to run to fix
it, and F<bin/guest_network> is that for a network that the block of
F<hypervisors.conf> describes.

=cut

# What to run to make the network of the static adapter $nic of this block, for
# the fix of a check.
my sub guest_network_fix ( $self, $nic = 'NIC' ) {
    my $name = $self->name // 'NAME';
    my $via  = $self->is_session ? ' --via ADMIN' : q{};
    return <<"FIX";
For the network of a bridge of static_nics in [$name], which the block describes
with ip_pool_$nic and gateway_$nic:

    bin/guest_network --hypervisor $name --nic $nic$via --dryrun

and again without --dryrun.  It defines the network on the system daemon,
starts it, starts it with the host, and lets the account of a session join its
bridge.@{[ $via ? "  ADMIN is the block of an account on the system URI of the\nsame host, with sudo." : q{} ]}
FIX
}

# The bridges of the guests, or a failed verdict that says why there are none.
my sub bridges_or_verdict ($self) {
    my @bridges = eval { $self->nic_bridges };
    return ( undef, @bridges ) if @bridges;
    return $self->verdict( 0, 'Could not work out the bridges of the guests', $@ );
}

=head2 $result = $hv->check_guest_bridges()

Passes when each bridge of L</nic_bridges> is a bridge on the hypervisor.  It
asks for F</sys/class/net/BRIDGE/bridge>, which the kernel has for a bridge and
for nothing else.

=cut

sub check_guest_bridges ($self) {
    my ( $failed, @bridges ) = bridges_or_verdict($self);
    return $failed if $failed;

    my @absent = grep { $self->run_cmd( qw{test -d}, "/sys/class/net/$_/bridge" ) != 0 } @bridges;
    return $self->verdict( 1, 'The guests join ' . join( ', ', @bridges ), q{} ) unless @absent;

    return $self->verdict( 0, 'No bridge ' . join( ', ', @absent ) . ' on ' . $self->describe, guest_network_fix( $self, $absent[0] ) . <<'FIX' );

A bridge of the host itself, such as the one on its LAN, is made in the network
configuration of the host, and the bridge of the default network by libvirt.
FIX
}

=head2 $result = $hv->check_guest_networks()

Passes when L</lease_nic> is the bridge of the C<default> network, whose leases
L</lease_ip($network, %opts)> reads, and each bridge of L</nic_bridges> that a
libvirt network owns belongs to a network that runs and starts with the host.  A
bridge that no network owns, such as the bridge of the LAN of the host, passes,
because libvirt does not start it.

=cut

sub check_guest_networks ($self) {
    my ( $failed, @bridges ) = bridges_or_verdict($self);
    return $failed if $failed;

    my @networks = eval {
        map { network_on( $self, $_ ) // () } @bridges;
    };
    return $self->verdict( 0, 'Could not ask libvirt for its networks', $@ ) if $@;

    my ($lease) = grep { $_->get_name eq 'default' } @networks;
    return $self->verdict( 0, "$bridges[0], the first of dhcp_nics, is not the bridge of the default network", <<"FIX" ) unless $lease && $lease->get_bridge_name eq $bridges[0];
This machine finds a guest by its lease on the default network of libvirt, and
the first adapter of dhcp_nics is the one that takes that lease.  Name the
bridge of the default network first in dhcp_nics:

    virsh net-info default
FIX

    my @down = grep { !( $_->is_active && $_->get_autostart ) } @networks;
    return $self->verdict( 1, 'Each network of a bridge of the guests runs, and starts with the host', q{} ) unless @down;

    my @names = map { $_->get_name } @down;
    return $self->verdict( 0, 'The network ' . join( ', ', @names ) . ' does not run, or does not start with the host', guest_network_fix($self) . <<"FIX" );

For the default network, or any other one, on the hypervisor:

@{[ join "\n", map { "    virsh net-start $_; virsh net-autostart $_" } @names ]}
FIX
}

=head2 $result = $hv->check_bridge_acl()

Passes on the system URI, whose daemon joins its guests to a bridge itself.  On
a session, passes when F</etc/qemu/bridge.conf>, and each file that it includes,
let the account join each bridge of L</nic_bridges>, as C<rules> and C<refused>
in L<Trog::HV::Libvirt::BridgeHelper> read them.

=cut

sub check_bridge_acl ($self) {
    return $self->verdict( 1, 'The system daemon joins its guests to their bridges itself', q{} ) unless $self->is_session;

    my ( $failed, @bridges ) = bridges_or_verdict($self);
    return $failed if $failed;

    # read_text dies here on this machine, and returns undef on another one.
    my $read = sub ($file) {
        my $text;
        eval { $text = $self->read_text($file); 1 } or return;
        return $text;
    };
    my $rules;
    eval { $rules = Trog::HV::Libvirt::BridgeHelper::rules($read); 1 } or do {
        chomp( my $why = $@ );
        return $self->verdict( 0, 'Could not read what qemu-bridge-helper allows', "$why, on " . $self->describe . "\n" );
    };

    my $user = $self->ssh_user // 'this account';

    my @refused = Trog::HV::Libvirt::BridgeHelper::refused( $rules, @bridges );
    return $self->verdict( 1, "qemu-bridge-helper lets $user join " . join( ', ', @bridges ), q{} ) unless @refused;

    return $self->verdict( 0, "qemu-bridge-helper does not let $user join " . join( ', ', @refused ), guest_network_fix( $self, $refused[0] ) . <<"FIX" );

For every bridge of the block, from the machine that provisions:

    bin/runner_account --hypervisor ADMIN --user $user ...

Each writes an allow line into $Trog::HV::Libvirt::BridgeHelper::CONF, or a file that it includes.
FIX
}

=head2 $result = $hv->check_guest_pool()

Passes when each pool of L<Trog::HV/static_pools> fits the network of its
bridge.  The network is the one of the libvirt network that owns the bridge, or
for a bridge that no libvirt network owns, such as the bridge of the LAN, the
first IPv4 address that the host has on it.  A bridge with neither passes,
because then nothing here knows its network.  The pool passes when that network
is L</nic_network($nic)>, so the guests get the prefix of the network,
and for a libvirt network also when the gateway of the bridge, if the block
names one, is the address of the host on it, and no DHCP range of it overlaps
the pool.

A guest with an address outside the network of its bridge cannot reach it.  A
DHCP range over the pool can lease an address of the pool to something else.

=cut

sub check_guest_pool ($self) {
    my @nics = $self->static_nics;
    return $self->verdict( 1, 'The guests take no address from a pool', q{} ) unless @nics;

    # The network that the host says the static adapter $nic is on, and what
    # is wrong with the pool and the prefix of the block for that network, as
    # sentences.  Nothing when nothing here knows the network of the bridge.
    my $faults = sub ($nic) {
        my $said = eval { $self->nic_network($nic) };
        chomp( $said = $@ ) unless defined $said;
        my $network = network_on( $self, $nic );
        if ( !$network ) {
            my ($on) = ( $self->capture_cmd("ip -o -4 addr show dev $nic 2>/dev/null") // q{} ) =~ m{\binet[ ](\d+(?:[.]\d+){3}/\d+)};
            return unless $on;
            my ( $address, $prefix ) = split m{/}, $on;
            my $real = Trog::HV::network_of( $address, $prefix );
            return ( "$real, where the host is $on", $real eq $said ? () : "the host is $on on $nic, in $real, and the block puts $nic in $said" );
        }
        my $name    = $network->get_name;
        my $facts   = network_facts( $network->get_xml_description(0) );
        my $pool    = $self->nic_pool($nic);
        my $gateway = eval { $self->nic_gateway($nic) };
        my @pool    = ( @{ $pool->{cidr} // [] }, map { s{/\d+\z}{}r } @{ $pool->{addresses} // [] } );

        return ( "the network $name", "$nic belongs to the network $name, which has no IPv4 address" ) unless $facts->{cidr};
        my @wrong = (
            ( $facts->{cidr} ne $said                           ? "$name is $facts->{cidr}, and the block puts $nic in $said, which the guests would take the prefix of" : () ),
            ( defined $gateway && $gateway ne $facts->{address} ? "gateway_$nic is $gateway, and the address of the host on $name is $facts->{address}"                  : () ),
            ( map { "$_ of ip_pool_$nic is outside $facts->{cidr}, the network $name" } outside_of( $facts->{cidr}, $pool ) ),
            ( map { "$_ of ip_pool_$nic is in a DHCP range of $name" } grep { Net::CIDR::cidrlookup( $_, @{ $facts->{leases} } ) } @pool ),
        );
        return ( "$facts->{cidr}, the network $name", @wrong );
    };

    my ( @fits, %wrong );
    foreach my $nic (@nics) {
        my ( $where, @wrong ) = eval { $faults->($nic) };
        return $self->verdict( 0, 'Could not ask libvirt for its networks', $@ ) if $@;
        if (@wrong) { $wrong{$nic} = \@wrong }
        else        { push @fits, defined $where ? "$nic in $where" : "$nic, whose network nothing here knows" }
    }
    return $self->verdict( 1, 'Each pool fits its bridge: ' . join( '; ', @fits ), q{} ) unless %wrong;

    my ($first) = sort keys %wrong;
    return $self->verdict(
        0, 'The pool of ' . join( ', ', sort keys %wrong ) . ' does not fit the network of its bridge',
        join(
            q{},
            map {
                my $nic = $_;
                map { "$_.\n" } @{ $wrong{$nic} }
            } sort keys %wrong
          )
          . "\n"
          . guest_network_fix( $self, $first )
          . <<"FIX" );

It refuses a pool that is not inside the network, and makes the network with
no DHCP and the prefix of the block.  Or change ip_pool_$first, gateway_$first
and prefix_$first in the block.
FIX
}

=head2 $result = $hv->note_libguestfs()

Passes when the hypervisor has C<virt-cat>, C<virt-ls> or C<virt-edit>, which
can read the disk of a guest that does not boot.

=cut

sub note_libguestfs {
    my ($self) = @_;

    my ($found) = grep { $self->run_cmd( 'sh', '-c', "command -v $_ >/dev/null 2>&1" ) == 0 } qw{virt-cat virt-ls virt-edit};

    return { ok => 1 } if $found;

    return { ok => 0, what => 'No libguestfs on the hypervisor', fix => <<'FIX' };
Without it, a guest that will not boot can only be looked at through its
console.  With it, its disk can be read while it is off -- the cloud-init log
of a guest that never came up, the netplan it was actually given -- and its
kernel command line can be edited to boot single-user, rather than driving
GRUB with timed keystrokes.

    sudo apt install libguestfs-tools
FIX
}

=head2 $result = $hv->note_swtpm()

Fails when the hypervisor has a TPM and no C<swtpm>.  Passes on a hypervisor
with no TPM, because L</has_tpm> gives its guests no TPM whether or not
C<swtpm> is installed.

=cut

sub note_swtpm {
    my ($self) = @_;

    return { ok => 1 } unless $self->run_cmd( 'sh', '-c', 'test -c /dev/tpmrm0' ) == 0;
    return { ok => 1 } if $self->run_cmd( 'sh', '-c', 'command -v swtpm >/dev/null 2>&1' ) == 0;

    return { ok => 0, what => 'This machine has a TPM, and no swtpm to share it out', fix => <<'FIX' };
Guests built here get an emulated TPM when swtpm is installed, which is what lets
anything on them seal a secret to the machine -- systemd-creds, LUKS, tPSGI's
vault key.  Without it they are built without one and do without.

    sudo apt install swtpm swtpm-tools
FIX
}

=head2 $result = $hv->note_pool_quota()

Fails when nothing limits the storage pool to less than the storage under it.
Passes when there is no pool yet, and when the hypervisor does not say enough
to tell.

libvirt does not count what anyone allocates.  On the system URI, every guest
runs as libvirt-qemu, so a disk quota has no UID to apply to.  Only a limit on
the storage under the pool limits the guests.  Without one, the pool can fill
the filesystem, or the zpool, that it shares with everything else.  This is a
note and not a check, because most hypervisors have no such limit.

The answer comes from the space available, not from libvirt.  libvirt sizes a
directory pool from C<statvfs> on its path, which is the same call that C<df>
makes, so the two always agree.  See C<pool_is_unlimited> for what is compared
instead.

=cut

sub note_pool_quota {
    my ($self) = @_;

    # Not through pool(), which defines and starts a pool it cannot find.  A
    # check must not build anything.
    my $name = $self->pool_name;
    eval { $self->vmm->get_storage_pool_by_name($name) } or return { ok => 1 };

    my $fstype = $self->pool_fstype;
    my $space  = $self->pool_space($fstype);
    return { ok => 1 } if !pool_is_unlimited( $space, $fstype );

    my $under = $fstype eq 'zfs' ? 'the zpool ' . zpool_of( $space->{source} ) : "the filesystem at $space->{mount}";
    return {
        ok   => 0,
        what => sprintf( 'The %s pool has no quota: %s has all %.1fGB that %s has free', $name, $space->{path}, $space->{avail} / $Provisioner::Vars::GB, $under ),
        fix  => pool_quota_advice( $fstype, $name, $space ),
    };
}

=head2 \%space = $hv->pool_space($fstype)

The space at the storage pool's directory, from one command on the hypervisor.
The keys are C<path>, the directory with its links resolved; C<avail>, the
bytes free there; C<source> and C<mount>, the filesystem that holds it; and
C<mount_avail>, the bytes free at that mount point.  On ZFS, C<$fstype> adds
C<zpool_avail>, the bytes free in the whole zpool.  Undef when the directory
does not exist or C<df> does not answer.

=cut

sub pool_space {
    my ( $self, $fstype ) = @_;

    # capture_cmd takes a shell string, and the pool path can come from a
    # configuration file.
    my $quoted = Trog::Utils::shell_quote( $self->pool_path );

    my @steps = (
        "p=\$(realpath -e $quoted) || exit 0",
        'echo "$p"',
        'df -B1 --output=avail,source,target "$p" | tail -n1',
        'df -B1 --output=avail "$(df --output=target "$p" | tail -n1)" | tail -n1',
    );
    push @steps, 's=$(df --output=source "$p" | tail -n1); zfs get -Hp -o value available "${s%%/*}"' if $fstype eq 'zfs';

    my $said = eval { $self->capture_cmd( '{ ' . join( '; ', @steps ) . '; } 2>/dev/null' ) } // q{};
    my ( $path, $here, $mount_avail, $zpool_avail ) = map { s/\A\s+|\s+\z//gr } split m/\n/, $said;
    return if !defined $here;

    # The mount point is last, so a space in it stays in it.
    my ( $avail, $source, $mount ) = split q{ }, $here, 3;
    return if !defined $mount || $avail !~ m/\A\d+\z/;

    return { path => $path, avail => $avail, source => $source, mount => $mount, mount_avail => $mount_avail, zpool_avail => $zpool_avail };
}

=head2 $bool = pool_is_unlimited(\%space, $fstype)

Whether the space at the pool, as C<pool_space> reports it, shows that nothing
limits it.  A quota shows up as less space free at the pool than at what
encloses it: a project quota on XFS or ext4 against its mount point, and a
dataset quota on ZFS against its zpool.  C<statfs> reports each of those limits
inside it.  A pool that is a mount point of its own, on anything but ZFS, is a
filesystem of its own, and that is its limit.

Returns false when C<%space> is undef or lacks the number to compare with,
because the note says nothing that it cannot show.  Free space within 1% of
what encloses it counts as the same, because the two are read a moment apart.

=cut

sub pool_is_unlimited {
    my ( $space, $fstype ) = @_;
    return if !$space;
    return if $fstype ne 'zfs' && $space->{path} eq $space->{mount};

    my $enclosing = $fstype eq 'zfs' ? $space->{zpool_avail} : $space->{mount_avail};
    return if !defined $enclosing || $enclosing !~ m/\A\d+\z/;
    return $space->{avail} * 100 >= $enclosing * 99;
}

=head2 $zpool = zpool_of($dataset)

The zpool that the ZFS dataset C<$dataset> belongs to, which is its name up to
the first slash.

=cut

sub zpool_of {
    my ($dataset) = @_;
    return ( split m{/}, $dataset )[0];
}

=head2 $text = pool_quota_advice($fstype, $name, \%space)

How to put a limit under the pool C<$name> on a filesystem of type C<$fstype>,
as C<stat -f> names it.  ZFS gets a dataset with a quota.  XFS and ext4 get a
project quota on the directory that the pool already has.  Anything else gets a
filesystem of its own.

=cut

sub pool_quota_advice {
    my ( $fstype, $name,  $space )  = @_;
    my ( $path,   $mount, $source ) = @{$space}{qw{path mount source}};

    my $why = <<'WHY';
Guests built here are limited by nothing but the storage under the pool, and
by reserve_disk in hypervisors.conf.  reserve_disk is this tool asking itself
for permission, and says nothing to anybody who drives virsh directly.
WHY

    # A project quota keeps the pool where it is.  Each other answer moves it,
    # and then hypervisors.conf must name both halves.
    my $move = <<"MOVE";
Then name both halves in hypervisors.conf.  libvirt finds a pool by its name,
and it ignores a pool_path beside the name of a pool that already exists:

    pool_path = <the new directory>
    pool_name = $name
MOVE

    my $how;
    if ( $fstype eq 'zfs' ) {
        my $zpool = zpool_of($source);
        $how = <<"ZFS" . "\n$move";
Give the pool a dataset of its own, with a quota:

    zfs create -o quota=500G $zpool/vm-disks/$name

`zfs get mountpoint $zpool/vm-disks/$name` names the new directory.
ZFS
    }
    elsif ( $fstype eq 'xfs' ) {
        $how = <<"XFS";
Put a project quota on the directory of the pool.  Pick a project ID that
nothing on $mount uses, such as 42.

XFS reads the prjquota option only when it mounts a filesystem.  A remount
succeeds, and it leaves quotas off.  So add prjquota to the options of $mount
in /etc/fstab, and unmount and mount it.  For the root filesystem, that means
rootflags=prjquota on the kernel command line and a reboot.  Then:

    xfs_quota -x -c 'project -s -p $path 42' $mount
    xfs_quota -x -c 'limit -p bhard=500g 42' $mount
XFS
    }
    elsif ( $fstype =~ m/\Aext/ ) {
        $how = <<"EXT";
Put a project quota on the directory of the pool.  Pick a project ID that
nothing on $mount uses, such as 42.

tune2fs adds the project and quota features only to a filesystem that is not
mounted.  For the root filesystem, that means a rescue boot.  Then mount it
with prjquota in its options in /etc/fstab.  If that mount fails with "No such
process", the kernel has no quota_v2 module, which Ubuntu ships in
linux-modules-extra-\$(uname -r).  Then:

    tune2fs -O project,quota $source
    chattr +P -p 42 $path
    setquota -P 42 0 524288000 0 0 $mount
EXT
    }
    else {
        $how = <<"OTHER" . "\n$move";
Give the pool a filesystem of its own, of a fixed size, such as a logical
volume, and mount it where the new directory of the pool will be.
OTHER
    }

    return "$why\n$how\nThis matters most on a hypervisor where an unattended runner can build.\nSee QUOTAS in Provisioner::Recipe::trogrunner.\n";
}

=head2 $result = $hv->note_log_destination()

Says whether anything keeps the logs of the guests.  It fails in two cases:

=over 4

=item * The hypervisor still has rsyslog drop-ins named F<10-DOMAIN.conf> for
known domains.  Old versions of this tool wrote them, and nothing uses them now.

=item * A domain runs C<logcollector>, and no domain runs C<logshipper>.

=back

It reads the configuration and uses the existing connection to the hypervisor.
It does not ask the IP pool, because that makes a read-only command create
F<ips.db>.

=cut

sub note_log_destination {
    my ($self) = @_;

    my $conf    = eval { Provisioner::Cookbook->configuration() } // {};
    my @domains = Provisioner::Cookbook->domains($conf);

    my ( $shipping, %collectors );
    foreach my $domain (@domains) {
        my $recipes = eval { Provisioner::Cookbook->domain_config( $domain, $conf ) } // {};
        $shipping            = 1 if exists $recipes->{logshipper};
        $collectors{$domain} = 1 if exists $recipes->{logcollector};
    }

    # Only the drop-ins for known domains.  Every other file there belongs to
    # the distribution or to another recipe.
    my %known = map       { $_ => 1 } @domains;
    my @stale = sort grep { $known{$_} }
      map { m/\A10-(\N+)[.]conf\z/ ? $1 : () } eval { $self->list_dir('/etc/rsyslog.d') };

    if (@stale) {

        # Commas and no spaces, so that the operator can paste the brace
        # expansion.
        my $braces = join( ',',  @stale );
        my $listed = join( "\n", map { "    $_" } @stale );
        my $where  = $self->describe;
        return { ok => 0, what => scalar(@stale) . " rsyslog drop-ins on the hypervisor are left over from before logging was a recipe", fix => <<"FIX" };
$where still carries a per-domain collector configuration for:

$listed

Provisioning wrote those, and no longer does -- where a guest sends its logs is
Provisioner::Recipe::logshipper now, and the listener at the other end is
Provisioner::Recipe::logcollector.  They route nothing unless something on that
machine is listening for syslog, which this tool no longer arranges.  Remove
them once you are satisfied nothing else put them to use:

    sudo rm /etc/rsyslog.d/10-{$braces}.conf
    sudo systemctl restart rsyslog
FIX
    }

    return { ok => 1 } unless %collectors;
    return { ok => 1 } if $shipping;

    my $built = join( ', ', sort keys %collectors );
    return { ok => 0, what => "$built collects logs, and nothing ships to it", fix => <<"FIX" };
Every guest is keeping its logs to itself, on its own disk, where they go when
the guest does.  Point the fleet at the collector:

    _base:
        logshipper:
            host: $built

Nothing depends on that recipe, and a guest that does not run it ships nowhere.
FIX
}

=head2 clear_guest($domain)

Removes what uses this domain name before a new build, and returns 1.

=over 4

=item * With C<keep_disk>, it stops the domain and reverts its disk to
C<trog-pristine>.  It dies if the revert fails.

=item * Without C<keep_disk>, it undefines the domain and deletes its disk.
The new disk is a new overlay, so the new guest does not get the old filesystem.

=back

In both cases, it deletes the seed ISO and releases each lease of the NAT MAC.

A rebuilt guest keeps its MAC, which comes from its name.  The network-config
of L<Provisioner::Recipe::ubuntu> sends that MAC as the DHCP client identifier,
so dnsmasq takes the rebuilt guest for the same client, and gives it back the
lease that it had.  A guest that sends a DUID instead is a new client after each
rebuild, because the DUID comes from the machine-id, which the rebuild makes
new.  Every guest built before that network-config sends one, and so does a
distribution whose network-config does not set the identifier.  dnsmasq gives
such a guest a new address and keeps the old lease.  Without the release, each
rebuild of it holds one more address in the NAT range.  Also, the wait in
C<provision_guest> finds the old lease and stops before the new guest asks.

=cut

sub clear_guest {
    my ( $self, $domain, %opts ) = @_;

    if ( $opts{keep_disk} ) {

        # Stopped, not undefined.  Undefining removes the libvirt snapshot
        # metadata, as annihilate_domain asks.  The new snapshot then stays in
        # the file, but the domain, and bin/restore, cannot see it.
        print "Keeping the disk for $domain, and putting it back to $PRISTINE_SNAPSHOT\n";
        $self->stop_domain($domain);
        $self->revert_disk( "$domain-qcow2", $PRISTINE_SNAPSHOT )
          or die "Could not put $domain-qcow2 back to $PRISTINE_SNAPSHOT on " . $self->describe . "\n";
    }
    else {
        if ( $self->domain_exists($domain) ) {
            print "Terminating the existing VM $domain\n";
            $self->annihilate_domain($domain);
        }

        $self->delete_volume("$domain-qcow2");
    }

    # The seed goes in both cases, because each provision writes a new one.
    $self->delete_volume("$domain-cloudinit.iso");

    $self->release_dhcp_lease($_) for $self->lease_ips( 'default', mac => $self->guest_mac( $domain, 0 ) );

    return 1;
}

=head2 $address = $hv->provision_guest($config, $seed, %opts)

Makes the guest: its disks and cloud-init seed, the domain XML, and the domain,
defined and started.  Returns the address that the guest leased on the NAT
network.  Dies if no lease appears within about 30 seconds.

C<$seed> is a hashref of the three NoCloud files, for
L</cloudinit_iso($domain, %files)>.
C<settings> is the configuration of the domain as a plain hash, which
C<bin/provision> reads from F<provision.conf>.  So this code does not need
L<Config::Simple>.  L<Provisioner::Recipe::vm> takes a hash for the same reason,
because its other caller, C<bin/new_config>, has no such object.

=cut

sub provision_guest {
    my ( $self, $config, $seed, %opts ) = @_;

    my $domain   = $config->param('domain');
    my %settings = %{ $opts{settings} // {} };
    my $dir      = $self->domain_dir . "/$domain";

    my $vm = Provisioner::Cookbook->load('vm')->new(
        template_dirs => Provisioner::Cookbook->template_dirs( $config->param('distro') ),
        output_dir    => $dir,
        hv            => $self,
    );

    # The disks, the base image and the seed ISO come first, because the XML
    # names them by path.
    my %storage = $vm->create_storage( %settings, domain => $domain, seed => $seed );

    # Only a rebuild that kept the disk finds a uuid.  See domain_uuid.  On a
    # first build it is undef, and the template leaves the element out.
    my $uuid = $self->domain_uuid($domain);

    # Only the keys that vm declares.  The rest of provision.conf is for
    # bin/provision and the first boot, and the recipe refuses unknown keys.
    $vm->generate_files( $dir, $vm->takes(%settings), %storage, domain => $domain, ( defined $uuid ? ( uuid => $uuid ) : () ) );

    my $file = "$dir/domain.xml";
    print "Wrote $file\n";    ## no critic (InputOutput::ProhibitRepeatedPrints) -- two messages, because this one ends generate_files and the next one starts define_domain

    print "Defining and starting $domain...\n";
    $self->define_domain( File::Slurper::read_text($file) );

    # clear_guest released the old leases of this MAC, so a lease that appears
    # is from this guest.  If the release failed, with a warning, this can find
    # an old lease.  wait_for_ssh makes sure that the guest is running.
    print "Looking up the address for $domain...";
    my $nat_mac = $self->guest_mac( $domain, 0 );
    my $address = q{};
    for ( 1 .. 30 ) {
        $address = $self->lease_ip( 'default', mac => $nat_mac );
        last if $address;
        print q{.};
        sleep 1;
    }
    die "\n$domain never asked for a lease!\n" unless $address;

    print "\n" . address_report( $domain, $address, $config->param('ips') );

    return $address;
}

=head2 $text = address_report($domain, $lease, @ips)

The lines that say where a guest that just started is: its NAT lease, and
each static address from C<ips> in F<provision.conf>, each named for what it
is.  C<guest_ssh_ip> decides which of them C<bin/provision> connects to.

=cut

sub address_report {
    my ( $domain, $lease, @ips ) = @_;
    my $report = "Defined and started $domain.\n" . "  NAT lease:      $lease, which only the hypervisor and its guests reach\n";
    $report .= "  static address: $_, from ips in provision.conf\n" for grep { $_ } @ips;
    return $report;
}

=head2 $hv->would_provision($config, %opts)

Prints the plan for C<clear_guest> and C<provision_guest>, and does not carry
it out.  Returns the current NAT lease of the guest, or C<bogus> when it has none.

=cut

sub would_provision {
    my ( $self, $config, %opts ) = @_;

    my $domain = $config->param('domain');
    my $plan   = q{};
    $plan .= "Would terminate the existing $domain and delete its volumes\n" if $self->domain_exists($domain);
    $plan .= "Would create the disk $domain-qcow2 and a cloud-init seed on " . $self->describe . ", then define and start $domain\n";
    print $plan;

    return $self->lease_ip( 'default', mac => $self->guest_mac( $domain, 0 ) ) // 'bogus';
}

=head1 RUNNER ACCOUNTS

A runner is a guest that builds guests: see L<Provisioner::Recipe::trogrunner>.
It can have an account of its own on a hypervisor, with a pool that has a quota
and sudo for only what a build runs.  The methods here make that account and
take it away.  Each returns actions for L<Trog::Steps/run>, so each change asks
first whether it is there, and a second run changes nothing.

They run as the account of this object, which needs sudo for everything.  That
is the account of the block in F<hypervisors.conf>, not the account that they
make.  F<bin/provision> runs them for a trogrunner block that asks for an
C<account>, and F<bin/runner_account> runs them by hand.

The account builds its guests in its own session of libvirt, on
C<qemu+ssh://USER@HOST/session>, and not on the system URI.  See
L</is_session>.  On the system URI an account needs the C<libvirt> group, and
that group can define a domain whose disk is any file or device of the host.
The system daemon opens it as root, so the account can read any file of the
host.  The polkit access driver of libvirt does not close that, because it
checks the names of objects and not the XML of a domain.  A session daemon
runs as the account, so its domains can open only what the account can open.

=cut

my sub sudoers_of ($user) { return "/etc/sudoers.d/90-trog-runner-$user" }
my sub linger_of  ($user) { return "/var/lib/systemd/linger/$user" }

# What a command printed, without its last newline, or an empty string.
my sub said ( $hv, $cmd ) {
    my $out = $hv->capture_cmd("$cmd 2>/dev/null") // q{};
    chomp $out;
    return $out;
}

# The home directory of $user, or an empty string when there is no such user.
my sub home_of ( $hv, $user ) { return said( $hv, 'getent passwd ' . Trog::Utils::shell_quote($user) . ' | cut -d: -f6' ) }

# The uid of $user, or an empty string when there is no such user.
my sub uid_of ( $hv, $user ) { return said( $hv, 'id -u ' . Trog::Utils::shell_quote($user) ) }

# The drop-in that limits the user slice of the account with $uid.
my sub slice_dropin ($uid) { return "/etc/systemd/system/user-$uid.slice.d/50-trog-runner.conf" }

# True when root finds no $file on the hypervisor.
my sub absent ( $hv, $file ) { return $hv->run_cmd( qw{sudo -n test ! -e}, $file ) == 0 }

=head2 $text = Trog::HV::Libvirt->runner_sudoers(%args)

The sudoers file for an account that builds guests on this hypervisor, and
cannot do anything else as root.  C<%args> takes C<user> and C<lease_helper>,
the second as a full path.  Dies if a value holds a character that sudoers or
the pattern below would read as syntax.

It grants one command, C<VIR_BRIDGE_NAME=$bridge $lease_helper del ip
$address>, from C<release_dhcp_lease>.  The file keeps C<VIR_BRIDGE_NAME> for
that command only.  Without that line, sudo refuses the variable, and so the
command.  The grant does not use C<SETENV>, because C<SETENV> lets the caller
set C<LD_PRELOAD> too.  The arguments are a regular expression, which sudo
1.9.10 and later accept.  Issue #539 of trog-provisioner removes the release,
and with it this file.

The other commands that a build runs as root on the system URI need no root in
a session.  qemu-img opens the disks of the account as the account, and a
session has no F</usr/libexec/virtiofs-better> to install.  Two commands that
need root are left out on purpose, and the account cannot run them:

=over 4

=item * The address sweep of L<Provisioner::IPPool/ensure_seeded>, which runs
C<sudo sh -c>.  That is root for any command, and cannot be narrowed.  Without
it, the sweep finds nothing, and the pool of the runner starts empty.  A
runner that takes DHCP addresses for its guests does not need it.

=item * The libguestfs tools and the console log of F<bin/debug_boot>.  Those
read the disk of any guest, which is the reason to run them.

=back

=cut

sub runner_sudoers {
    my ( $class, %args ) = @_;

    # sudoers reads , : = \ ! and space as syntax.  None of them has a reason
    # to be in these.
    foreach my $key (qw{user lease_helper}) {
        my $value = $args{$key} // die "runner_sudoers needs $key\n";
        my $ok    = $key eq 'user' ? $Trog::Patterns::ACCOUNT_NAME : qr{\A(?:/[\w.-]+)+\z};
        die "runner_sudoers: '$value' is not a $key that a sudoers file can hold as written\n" unless $value =~ $ok;
    }
    my ( $user, $lease ) = @args{qw{user lease_helper}};

    return <<"SUDOERS";
# What trog-provisioner runs as root on this hypervisor for $user, and nothing
# else.  Written by runner_account_steps.  runner_sudoers in Trog::HV::Libvirt
# says why the line is here, and which commands are left out.
Defaults!$lease env_keep += "VIR_BRIDGE_NAME"
$user ALL=(root) NOPASSWD: $lease ^del ip [0-9.]+\$
SUDOERS
}

=head2 \%plan = Trog::HV::Libvirt->runner_account_plan(%args)

Checks what an account is to be, and returns what the methods below need.
C<%args> takes C<user>, C<pool_name> and C<pool_path>, which are required, and
C<quota>, C<cores>, C<io_weight> and C<bridges>.  The plan has those.

C<bridges> is a reference to the list of the bridges that the guests of the
account may join: the C<dhcp_nics> and the C<static_nics> of the block of the
runner, not of the block that makes the account.

C<cores> is the CPU time that the guests of the account get together, in
whole cores of the host, such as 16.  The user slice of the account gets it as
C<CPUQuota>, 100% for each core.

C<quota> is required to make an account, and not to take one away, and so are
C<bridges>, so this does not require them.  Dies on a value that a step would write into a file or a
command as syntax.

=cut

sub runner_account_plan {
    my ( $class, %args ) = @_;

    foreach my $key (qw{user pool_name pool_path}) {
        die "An account for a runner needs a $key\n" if ( $args{$key} // q{} ) eq q{};
    }

    # The match is ASCII under /aa, so \w and \d mean what useradd, zfs and
    # systemd accept.
    die "user '$args{user}' is not a name useradd takes\n"                  unless $args{user}      =~ $Trog::Patterns::ACCOUNT_NAME;
    die "pool_name '$args{pool_name}' has to be letters, digits, _ and -\n" unless $args{pool_name} =~ m/\A[\w-]+\z/;
    die "pool_path '$args{pool_path}' has to be an absolute path of letters, digits, _ . and -\n"
      if $args{pool_path} !~ m{\A(?:/[\w.-]+)+\z} || $args{pool_path} =~ m{/[.]{1,2}(?:/|\z)};
    die "quota '$args{quota}' is not a size zfs reads, such as 500G\n" if defined $args{quota} && $args{quota} !~ m/\A\d+[KMGTP]?\z/;

    die "cores '$args{cores}' has to be a whole number of cores, 1 or more, such as 16\n"
      if defined $args{cores} && ( $args{cores} !~ m/\A\d+\z/ || $args{cores} < 1 );
    die "io_weight '$args{io_weight}' has to be from 1 to 10000\n"
      if defined $args{io_weight} && ( $args{io_weight} !~ m/\A\d+\z/ || $args{io_weight} < 1 || $args{io_weight} > 10_000 );

    if ( defined $args{bridges} ) {
        die "bridges is a list of the bridges that the guests of the account may join\n" unless ref $args{bridges} eq q{ARRAY} && @{ $args{bridges} };
        my ($bad) = grep { !m/$Trog::Patterns::LINK_NAME/ } @{ $args{bridges} };
        die "bridge '$bad' is not the name of a link\n" if defined $bad;
    }

    return { map { $_ => $args{$_} } qw{user pool_name pool_path quota cores io_weight bridges} };
}

=head2 @actions = $hv->runner_account_steps(\%plan)

The actions that make the account of C<\%plan>, in order:

=over 4

=item 1. A system user with no password, a shell and a home, in the C<kvm>
group, which opens F</dev/kvm>.  Not in the C<libvirt> group: see
L</RUNNER ACCOUNTS>.

=item 2. A ZFS dataset at C<pool_path>, with C<quota> set to the C<quota> of the
plan.  Its parent is the dataset mounted on the parent directory of
C<pool_path>.  The user owns it, with mode 0700.

=item 3. Lingering for the user, so that systemd keeps the user slice and the
guests of the session after the login that started them ends.

=item 4. The storage pool C<pool_name> at C<pool_path>, in the session of the
user, started with the session.  It runs as the user, in its systemd manager,
because the connection of this object cannot reach the session of another
user.  The pool must be there before the first build, because placement asks
it for its free space.

=item 5. With C<cores> or C<io_weight>, a drop-in for the user slice,
F<user-UID.slice>, with C<CPUQuota> and C<IOWeight>.  There is no limit for
memory, because C<MemoryMax> on a slice kills a guest rather than refusing the
next one.  C<max_memory> is the budget that refuses it instead.  See QUOTAS in
L<Provisioner::Recipe::trogrunner>.

=item 6. The bridges that qemu-bridge-helper lets the user join: the
C<bridges> of the plan, and no other.  A bridge that the file allowed before
and the plan does not name goes.  See C<allow_only_steps> in
L<Trog::HV::Libvirt::BridgeHelper>.

=item 7. The C<cap_net_admin> capability on qemu-bridge-helper, and an apt
hook that sets it again after each package upgrade.  See C<capability_steps> in
L<Trog::HV::Libvirt::BridgeHelper>, which says why the helper needs it.

=item 8. The sudoers file F</etc/sudoers.d/90-trog-runner-USER>, which
C<runner_sudoers> writes.  C<visudo -c> makes sure that it is valid before it
is installed.

=back

Before the first, it makes sure that the hypervisor has what every step needs,
and dies with the reason if one is missing: a quota in the plan, sudo 1.9.10
or later for the pattern of the grant, the lease helper, F</dev/kvm>,
qemu-bridge-helper, apt for the hook, the bridges of the plan, and ZFS under the parent
of the pool.  On a filesystem other than ZFS, the message says how to put a
quota there, which is the advice of C<note_pool_quota>.

=cut

sub runner_account_steps {
    my ( $hv, $plan ) = @_;
    my ( $user, $path, $name ) = @{$plan}{qw{user pool_path pool_name}};

    die "An account for a runner needs a quota for its pool, or the pool can fill the disk of the hypervisor\n" unless defined $plan->{quota};

    my ($version) = said( $hv, 'sudo -V' ) =~ m/version\s+(\d+)[.](\d+)[.](\d+)/ ? ( sprintf '%d.%03d%03d', $1, $2, $3 ) : (0);
    die "sudo on " . $hv->describe . " is older than 1.9.10, which is the first that takes the patterns the grant needs\n" if $version < 1.009010;

    my $lease = $hv->lease_helper or die 'There is no libvirt lease helper on ' . $hv->describe . "\n";
    $hv->run_cmd(qw{test -c /dev/kvm}) == 0
      or die 'There is no /dev/kvm on ' . $hv->describe . ", so the guests of a session would run without KVM.\n";
    my $helper = Trog::HV::Libvirt::BridgeHelper::helper($hv) or die 'There is no qemu-bridge-helper on ' . $hv->describe . ", which a session needs to put a guest on a bridge.\n";
    $hv->run_cmd(qw{test -d /etc/apt/apt.conf.d}) == 0
      or die 'There is no apt on ' . $hv->describe . ", so nothing would set the capability of $helper again after a package upgrade.\n";
    die "An account for a runner needs the bridges that its guests may join\n" unless $plan->{bridges};
    my @bridges = @{ $plan->{bridges} };

    my $parent = File::Basename::dirname($path);
    my $fstype = $hv->path_fstype($parent);
    die "The parent of $path is on '$fstype', and a pool of a runner can have a quota here only on ZFS.\n" . pool_quota_advice( $fstype, $name, { path => $path, mount => $parent, source => $parent } )
      unless $fstype eq 'zfs';

    my $parent_set = said( $hv, 'zfs list -H -o name ' . Trog::Utils::shell_quote($parent) );
    my $mounted_at = said( $hv, 'zfs get -H -o value mountpoint ' . Trog::Utils::shell_quote($parent_set) );
    die "$parent is not where a ZFS dataset is mounted (it is inside $parent_set, mounted at $mounted_at), so a child dataset would not mount at $path\n"
      unless $parent_set && $mounted_at eq $parent;
    my $dataset = "$parent_set/" . File::Basename::basename($path);

    # The drop-in of the user slice, and the action that installs it.  The uid
    # is asked when the step runs, because the first step makes the user.
    my @slice;
    if ( defined $plan->{cores} || defined $plan->{io_weight} ) {
        my $text = join "\n", "# The guests of the trog-provisioner runner $user.  See runner_account_steps", '# in Trog::HV::Libvirt.', '[Slice]',
          ( defined $plan->{cores}     ? sprintf( 'CPUQuota=%d%%', $plan->{cores} * 100 ) : () ),
          ( defined $plan->{io_weight} ? "IOWeight=$plan->{io_weight}"                    : () );
        @slice = {
            what => "limit the user slice of $user",
            done => sub { my $uid = uid_of( $hv, $user ); $uid ne q{} && $hv->root_text( slice_dropin($uid) ) eq $text },
            do   => sub {
                my $file = slice_dropin( uid_of( $hv, $user ) );
                $hv->run_sudo_or_die( qw{install -d -m 0755}, File::Basename::dirname($file) );
                $hv->write_text( $file, "$text\n", sudo => 1, mode => '0644' ) or die "Could not write $file\n";
                $hv->run_sudo_or_die(qw{systemctl daemon-reload});
            },
        };
    }

    my $sudoers = sudoers_of($user);
    my $grant   = Trog::HV::Libvirt->runner_sudoers( user => $user, lease_helper => $lease );

    # virsh as $user, in its own systemd manager.  So the session daemon that
    # it starts belongs to the account, and stops when the account stops
    # lingering, and not with the login of the operator.
    my @virsh        = ( qw{systemd-run --quiet --wait --pipe}, "--machine=$user\@.host", qw{--user virsh -q -c qemu:///session} );
    my $session_says = sub ( $verb, $pool ) { said( $hv, join q{ }, 'sudo -n', @virsh, $verb, Trog::Utils::shell_quote($pool) ) };

    my @steps = (
        {
            what => "make the user $user, with no password",
            done => sub { uid_of( $hv, $user ) ne q{} },
            do   => sub { $hv->run_sudo_or_die( qw{useradd --system --create-home --shell /bin/bash}, $user ) },
        },
        {
            what => "put $user in the kvm group",
            done => sub {
                List::Util::any { $_ eq 'kvm' } split q{ }, said( $hv, 'id -nG ' . Trog::Utils::shell_quote($user) );
            },
            do => sub { $hv->run_sudo_or_die( qw{usermod -aG kvm}, $user ) },
        },
        {
            what => "make the ZFS dataset $dataset at $path",
            done => sub { said( $hv, 'zfs list -H -o name ' . Trog::Utils::shell_quote($dataset) ) eq $dataset },
            do   => sub { $hv->run_sudo_or_die( qw{zfs create -o}, "quota=$plan->{quota}", $dataset ) },
        },
        {
            what => "set the quota of $dataset to $plan->{quota}",
            done => sub { uc said( $hv, 'zfs get -H -o value quota ' . Trog::Utils::shell_quote($dataset) ) eq uc $plan->{quota} },
            do   => sub { $hv->run_sudo_or_die( qw{zfs set}, "quota=$plan->{quota}", $dataset ) },
        },
        {
            what => "give $path to $user, with mode 0700",
            done => sub { said( $hv, 'stat -c %U:%a ' . Trog::Utils::shell_quote($path) ) eq "$user:700" },
            do   => sub { $hv->run_sudo_or_die( 'chown', "$user:", $path ); $hv->run_sudo_or_die( qw{chmod 0700}, $path ) },
        },
        {
            what => "let the guests of $user run while it is not logged in",
            done => sub { !absent( $hv, linger_of($user) ) },
            do   => sub { $hv->run_sudo_or_die( qw{loginctl enable-linger}, $user ) },
        },
        {
            what => "define the storage pool $name at $path in the session of $user, started with the session",
            done => sub {
                my $xml = $session_says->( 'pool-dumpxml', $name );
                my ($target) = $xml =~ m{<target>.*?<path>([^<]+)</path>} or return 0;
                die "The session of $user already has a pool $name at $target, and libvirt finds a pool by its name: pick another pool_name, or remove that pool\n" if $target ne $path;
                my $info = $session_says->( 'pool-info', $name );
                return $info =~ m/^State:\s+running\s*$/m && $info =~ m/^Autostart:\s+yes\s*$/m;
            },

            # No pool-build: the steps above made the directory and gave it to
            # the user, and a session daemon that starts finds it there and
            # marks the pool running, which pool-build then refuses.
            do => sub {
                $hv->run_sudo_or_die( @virsh, qw{pool-define-as}, $name, qw{dir --target}, $path ) if $session_says->( 'pool-dumpxml', $name ) eq q{};
                $hv->run_sudo_or_die( @virsh, 'pool-start',       $name ) unless $session_says->( 'pool-info', $name ) =~ m/^State:\s+running$/m;
                $hv->run_sudo_or_die( @virsh, 'pool-autostart',   $name );
            },
        },
        @slice,
        Trog::HV::Libvirt::BridgeHelper::allow_only_steps( $hv, $user, @bridges ),
        Trog::HV::Libvirt::BridgeHelper::capability_steps( $hv, $helper ),
        {
            what => "grant $user sudo for the lease release, in $sudoers",
            done => sub { chomp( my $wanted = $grant ); $hv->root_text($sudoers) eq $wanted },
            do   => sub {
                my $staged = said( $hv, 'mktemp' ) or die 'Could not make a temporary file on ' . $hv->describe . "\n";
                $hv->write_text( $staged, $grant ) or die "Could not stage the sudoers file\n";
                my $checked = $hv->run_sudo( qw{visudo -c -f}, $staged ) == 0;
                $checked &&= $hv->run_sudo_or_die( qw{install -o root -g root -m 0440}, $staged, $sudoers );
                $hv->remove($staged);
                die "visudo refused the sudoers file for $user, so it was not installed\n" unless $checked;
            },
        },
    );
    return @steps;
}

=head2 @actions = $hv->runner_removal_steps(\%plan)

The actions that take the account of C<\%plan> away, in the other order from
C<runner_account_steps>.  The user goes with its home, and the keys and the
session configuration of libvirt in it.  The dataset goes with C<zfs destroy>,
without C<-r>, so a snapshot or a child dataset stops it.  The capability of
qemu-bridge-helper and its apt hook go only with the last account that
needs them.

It refuses to start, and dies, while the directory of the pool holds a file
other than a base image of C<base_image>, because that is a disk of a guest.
Destroy the guests of the runner first.  So a refusal leaves the whole account,
and not an account without its sudo or its slice.

=cut

sub runner_removal_steps {
    my ( $hv,   $plan ) = @_;
    my ( $user, $path ) = @{$plan}{qw{user pool_path}};

    my $dataset = sub { said( $hv, 'zfs list -H -o name ' . Trog::Utils::shell_quote($path) ) };
    my $helper  = Trog::HV::Libvirt::BridgeHelper::helper($hv);

    # The session keeps no volume that the directory does not have.  A base
    # image is a download that any guest can fetch again, and not a disk.
    my $refuse_if_full = sub {
        my $first = said( $hv, 'sudo -n find ' . Trog::Utils::shell_quote($path) . q{ -mindepth 1 ! -name 'baseimage-*' -print -quit} );
        die "$path still holds $first, and maybe more, so the account $user stays.  Destroy the guests of the runner first.\n" if $first ne q{};
    };
    $refuse_if_full->();

    return (
        {
            what => 'remove ' . sudoers_of($user),
            done => sub { absent( $hv, sudoers_of($user) ) },
            do   => sub { $hv->run_sudo_or_die( qw{rm -f}, sudoers_of($user) ) },
        },
        Trog::HV::Libvirt::BridgeHelper::revoke_steps( $hv, $user ),
        Trog::HV::Libvirt::BridgeHelper::capability_removal_steps( $hv, $helper, $user ),
        {
            what => "remove the limits of the user slice of $user",
            done => sub { my $uid = uid_of( $hv, $user ); $uid eq q{} || absent( $hv, slice_dropin($uid) ) },
            do   => sub {
                my $file = slice_dropin( uid_of( $hv, $user ) );
                $hv->run_sudo_or_die( qw{rm -f},                            $file );
                $hv->run_sudo_or_die( qw{rmdir --ignore-fail-on-non-empty}, File::Basename::dirname($file) );
                $hv->run_sudo_or_die(qw{systemctl daemon-reload});
            },
        },
        {
            what => "stop the lingering of $user",
            done => sub { absent( $hv, linger_of($user) ) },
            do   => sub { $hv->run_sudo_or_die( qw{loginctl disable-linger}, $user ) },
        },
        {
            # By the slice, because a session daemon outlives the login that
            # started it, in a scope that logind calls abandoned and does not
            # end.  userdel refuses a user that still has a process.
            what => "stop every process of $user",
            done => sub { my $uid = uid_of( $hv, $user ); $uid eq q{} || said( $hv, "systemctl is-active user-$uid.slice" ) ne 'active' },
            do   => sub { $hv->run_sudo_or_die( qw{systemctl stop}, 'user-' . uid_of( $hv, $user ) . '.slice' ) },
        },
        {
            what => "destroy the ZFS dataset at $path",
            done => sub { my $set = $dataset->(); !$set || said( $hv, 'zfs get -H -o value mountpoint ' . Trog::Utils::shell_quote($set) ) ne $path },
            do   => sub { $refuse_if_full->();    $hv->run_sudo_or_die( qw{zfs destroy}, $dataset->() ) },
        },
        {
            what => "remove the user $user and its home",
            done => sub { uid_of( $hv, $user ) eq q{} },
            do   => sub { $hv->run_sudo_or_die( qw{userdel --remove}, $user ) },
        },
    );
}

# Writes $path, an authorized_keys file, without the lines that hold $material
# and with @add after them.
my sub rewrite_keys ( $hv, $path, $material, @add ) {
    return $hv->rewrite_lines( $path, mode => '0600', keep => sub ($line) { index( $line, $material ) < 0 }, add => \@add );
}

=head2 @actions = $hv->runner_key_steps($user, $line)

The action that lets the key of C<$line>, a line of F<authorized_keys>, log in
as C<$user>.  It writes as root, so the account of this object needs no login
as C<$user>.  So the key of the operator never has to go into an account that is
meant to be narrow.

The key is the second field of the line after its options, such as C<from=>.  The
line replaces every line with that key, so a new C<from=> restriction does not
leave the old line beside it.  sshd takes the first line that matches.

=cut

sub runner_key_steps {
    my ( $hv, $user, $line ) = @_;

    # The field after the type, with any options in front of the type skipped.
    my @fields     = split q{ }, $line;
    my ($type)     = grep { $fields[$_] =~ m/\A(?:ssh|ecdsa|sk)-/ } 0 .. $#fields;
    my ($material) = defined $type ? $fields[ $type + 1 ] : undef;
    die "'$line' is not a line of authorized_keys with a key in it\n" if length( $material // q{} ) <= 32;
    my ($comment) = $line =~ m/\Q$material\E\s*(.*)\z/;

    return {
        what => 'let ' . ( $comment || 'a key' ) . " log in as $user",
        done => sub {
            my @lines = grep { index( $_, $material ) >= 0 } split m/\n/, $hv->root_text( home_of( $hv, $user ) . '/.ssh/authorized_keys' );
            @lines == 1 && $lines[0] eq $line;
        },
        do => sub {
            my $home = home_of( $hv, $user ) or die "There is no user $user on " . $hv->describe . " to let a key in as\n";
            $hv->run_sudo_or_die( qw{install -d -m 0700 -o}, $user, '-g', $user, "$home/.ssh" );
            rewrite_keys( $hv, "$home/.ssh/authorized_keys", $material, $line );
            $hv->run_sudo_or_die( 'chown', "$user:", "$home/.ssh/authorized_keys" );
        },
    };
}

=head2 @actions = $hv->runner_key_removal_steps($user, $material)

The action that takes every line with the key C<$material> out of the
F<authorized_keys> of C<$user>, as root.  It has nothing to do when the user or
the file is not there.  Dies on a C<$material> that is too short to be a key,
because a short string can match half the file.

=cut

sub runner_key_removal_steps {
    my ( $hv, $user, $material ) = @_;
    die "'" . ( $material // q{} ) . "' does not look like a key; refusing to match on it\n" if length( $material // q{} ) <= 32;

    my $file = sub { my $home = home_of( $hv, $user ); $home ? "$home/.ssh/authorized_keys" : undef };
    return {
        what => "take the key ..." . substr( $material, -12 ) . " away from $user",
        done => sub {
            my $path = $file->() // return 1;
            index( $hv->root_text($path), $material ) < 0;
        },
        do => sub {
            my $path = $file->();
            rewrite_keys( $hv, $path, $material );
            $hv->run_sudo_or_die( 'chown', "$user:", $path );
        },
    };
}

=head1 SEE ALSO

L<Sys::Virt>

=cut

1;
