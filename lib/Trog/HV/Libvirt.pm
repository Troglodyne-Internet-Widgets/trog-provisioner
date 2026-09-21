package Trog::HV::Libvirt;

#ABSTRACT: the libvirt backend: domains, storage pools and the facts of a qemu host.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::HV';

use Sys::Virt();
use Digest::SHA();
use URI();
use URI::Split();

use Trog::Local();
use File::Slurper();
use Cpanel::JSON::XS();
use Provisioner::Cookbook();

# The snapshot of a new, empty overlay, which a rebuild that keeps the disk
# reverts to.  create_disk takes it and clear_guest reverts to it.  It is
# declared at the top because a file-scoped my is not visible above its line.
my $PRISTINE_SNAPSHOT = 'trog-pristine';

# The suffix that clone_guest_disk gives a copy, and that backup_volumes finds.
my $BACKUP_SUFFIX = '.bak-qcow2';

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

# The transports that also give us a shell on the hypervisor.
my %SSH_TRANSPORT = map { $_ => 1 } qw{ssh libssh libssh2};

=head2 marker

Returns C<uri>, the option that makes a block a libvirt one, from
C<libvirt_uri>.  A block with no backend's marker is one too, because this
backend can talk to the machine it runs on.

=head2 config_keys

Returns the pairs of constructor option and F<hypervisors.conf> key that this
backend reads.  A block with C<libvirt_uri> in it is a block for this backend.

=cut

sub marker { return 'uri' }

sub config_keys {
    return (
        uri => 'libvirt_uri',
        map { $_ => $_ } qw{pool_path pool_name domain_dir bridge_device virbr_device partition},
    );
}

=head2 build(%given)

Returns a new object for this backend.  L<Trog::HV/candidate> calls it after it
selects this backend for the options.

C<uri> defaults to C<qemu:///system>.  See L</explicit> for what the default
changes.

Dies if the URI does not parse.  Also dies if the hypervisor is remote and the
transport gives no shell, because files and bridge detection need one.

=cut

sub build {
    my ( $class, %given ) = @_;

    my $uri      = $given{uri};
    my $explicit = defined($uri) ? 1 : 0;
    $uri = $DEFAULT_URI unless $explicit;

    my $parsed = _parse_uri($uri)
      or die "Could not parse libvirt connection URI '$uri'\n";

    my $self = bless {
        %given,
        uri      => $uri,
        explicit => $explicit,
        %$parsed,
    }, $class;

    # Fail now, not three minutes into a provision.
    die "The hypervisor at $uri is remote, but its transport gives us no shell.\n" . "Use an ssh transport instead, e.g. qemu+ssh://root\@" . ( $self->{host} // 'hypervisor' ) . "/system, so we can reach its filesystem.\n"
      if !$self->is_local && !defined $self->ssh_host;

    return $self;
}

# A libvirt connection URI has the form driver[+transport]://[user@][host][:port]/path.
#
# URI does not know the driver+transport scheme, so it returns a URI::_foreign
# with no authority accessors.  We split the URI and parse the authority again
# as ssh.  That gives user, bracketed IPv6 and port without our own regex.
sub _parse_uri {
    my ($uri) = @_;

    my ( $scheme, $authority, $path ) = URI::Split::uri_split($uri);
    return undef unless $scheme;

    my ( $driver, $transport ) = split( quotemeta('+'), $scheme, 2 );
    return undef unless $driver;

    my $server = $authority ? URI->new("ssh://$authority") : undef;

    return {
        driver    => $driver,
        transport => $transport,
        user      => $server                      ? $server->user : undef,
        host      => ( $server && $server->host ) ? $server->host : undef,
        port      => $server                      ? $server->port : undef,
        path      => $path,
    };
}

=head1 IDENTITY

=head2 uri

The libvirt connection URI.  The default is C<qemu:///system>.

=head2 explicit

True when the caller gave a URI, false when the URI is the default.  When it is
false, libvirt selects its own default connection, as C<virsh> does with no
C<-c>.  L<Trog::HV/explicit> says what callers do with it.

=head2 is_local

True when the hypervisor is the machine that runs this code.

=cut

sub uri ($self) { return $self->{uri} }

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

=cut

sub pool_name ($self) { return $self->{pool_name} // 'tf_disks' }
sub partition ($self) { return $self->{partition} }

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

    # An empty URI lets libvirt select its default, as virsh does with no -c.
    my $uri = $self->explicit ? $self->uri : '';
    $self->{vmm} = eval { Sys::Virt->new( uri => $uri, readonly => 0 ) }
      or die "Could not connect to libvirt at " . $self->uri . ": $@\n";
    return $self->{vmm};
}

# A domain lookup dies when there is no such domain, which is not an error for
# any caller here.  The connection opens outside the eval, so a hypervisor that
# we cannot reach does not look like "no such domain".
sub _domain {
    my ( $self, $name ) = @_;
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

sub domain_exists ( $self, $name ) { return defined $self->_domain($name) ? 1 : 0 }

=head2 stop_domain($name)

Stops a domain and leaves it defined.  Returns 1 if the domain exists, and 0 if
it does not.  Dies if libvirt cannot stop it.

A rebuild that keeps the disk of a guest stops the guest but does not undefine
it.  qemu-img then writes the image directly, and the image gets corrupted if
qemu has it open.

=cut

sub stop_domain {
    my ( $self, $name ) = @_;
    my $domain = $self->_domain($name) or return 0;

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
    my $domain = $self->_domain($name) or return 0;

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

    my $domain = $self->_domain($name)
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
    return $self->capture_cmd("sudo cat '$log'") || undef;
}

=head2 ($advice, $port) = $hv->vnc_access($name)

The VNC port of the domain, and how to reach it.  The display listens on the
loopback of the hypervisor, so the advice is the ssh tunnel to it.

Dies if there is no such domain, or if it has no display with a port.  A
display with C<autoport='yes'> has C<port='-1'> until the domain runs.

=cut

sub vnc_access {
    my ( $self, $name ) = @_;

    my $domain = $self->_domain($name)
      or die "No domain called $name on " . $self->describe . "\n";

    my $port = _vnc_port( $domain->get_xml_description() )
      or die "$name has no display to connect to.\n";

    my $through = $self->ssh_target // 'localhost';
    my $advice  = <<"TUNNEL";
$name has VNC on port $port, on the hypervisor's loopback.

  ssh -N -L $port:127.0.0.1:$port $through
  then point a VNC client at 127.0.0.1:$port

TUNNEL

    return ( $advice, $port );
}

# The port of the VNC display in the live definition of a domain, or undef when
# there is no VNC display with a port of its own yet.
sub _vnc_port {
    my ($xml) = @_;

    foreach my $graphics ( $xml =~ m{<graphics\b[^>]*>}g ) {
        next if index( $graphics, q{type='vnc'} ) < 0;
        my ($port) = $graphics =~ m{\bport='(-?\d+)'};
        return $port if defined $port && $port > 0;
    }

    return undef;
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
    my $domain = $self->_domain($name) or return undef;

    return eval { $domain->get_uuid_string() };
}

=head2 annihilate_domain($name)

Stops and undefines a domain, with its nvram and its snapshot metadata.  A domain
that is already off is not an error.  Returns 1 if there was a domain to remove,
and 0 if not.  Dies if libvirt cannot undefine it.

=cut

sub annihilate_domain {
    my ( $self, $name ) = @_;
    my $domain = $self->_domain($name) or return 0;

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

    my $vmm = $self->vmm;
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
defaults to L</virbr_device>.  Returns 1 if the release worked.  Returns 0 if
it failed, if C<$ip> is empty, or if there is no lease helper.

This is the only libvirt operation that runs a command.  libvirt gives DHCP
leases read-only, and C<virNetworkGetDHCPLeases> has no delete operation.  So
this runs the libvirt lease helper on the hypervisor, as root.

=cut

sub release_dhcp_lease {
    my ( $self, $ip, $bridge ) = @_;
    return 0 unless $ip;
    $bridge //= $self->virbr_device;

    my ($helper) = grep { $self->file_exists($_) } qw{/usr/lib/libvirt/libvirt_leaseshelper /usr/libexec/libvirt_leaseshelper};
    unless ($helper) {
        warn "No libvirt lease helper found on the hypervisor, leaving the lease for $ip alone\n";
        return 0;
    }

    return $self->run_sudo( "VIR_BRIDGE_NAME=$bridge", $helper, qw{del ip}, $ip ) == 0 ? 1 : 0;
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

    my $domain = $self->_domain($name) or return 0;
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

    my $vmm  = $self->vmm;
    my $pool = eval { $vmm->get_storage_pool_by_name($name) };

    unless ($pool) {
        my $path = $self->pool_path;
        print "Defining storage pool $name at $path\n";

        $pool = $vmm->define_storage_pool(<<"XML");
<pool type='dir'>
  <name>$name</name>
  <target><path>$path</path></target>
</pool>
XML
        eval { $pool->build( Sys::Virt::StoragePool::BUILD_NEW() ); 1 } or do {
            die "Could not build the storage pool $name at $path: $@";
        };
        $pool->set_autostart(1);
    }

    if ( !$pool->is_active() ) {
        eval { $pool->create(); 1 } or do {
            die "Could not start the storage pool $name: $@";
        };
    }
    return $self->{_pools}{$name} = $pool;
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

=head2 base_image($url, $name)

Returns the path of the base image under the disk of each guest.  If the pool has
no volume C<$name>, this downloads C<$url> to the hypervisor first.  C<$name>
defaults to C<baseimage-qcow2>.  Dies if there is no image and no URL, or if
the download fails.

libvirt cannot fetch a URL.  So this runs curl on the hypervisor, into the pool
directory, and then refreshes the pool.  curl runs without sudo on purpose.  If
this account cannot write to the pool directory, the pool is misconfigured, and
sudo hides that.

=cut

sub base_image {
    my ( $self, $url, $name ) = @_;
    $name //= 'baseimage-qcow2';

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
      ? "<backingStore><path>" . _xml_escape($backing) . "</path><format type='qcow2'/></backingStore>"
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
  <name>@{[ _xml_escape($name) ]}</name>
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

=cut

sub delete_volume {
    my ( $self, $name, $pool ) = @_;
    my $volume = $self->volume( $name, $pool ) or return 0;
    eval { $volume->delete(0); 1 } or do { warn "Could not delete the volume $name: $@"; return 0 };
    return 1;
}

sub refresh_pool {
    my ( $self, $name ) = @_;
    eval { $self->pool($name)->refresh(); 1 } or do {
        die 'Could not refresh the storage pool ' . ( $name // $self->pool_name ) . ": $@";
    };
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

=head2 nic_slots

The PCI slots of the two interfaces, in order.  systemd names a PCI NIC after
its hotplug slot.  So fixed slots keep the names the same when the device list
changes.

=head2 nic_prefix

The start of the name that a guest here gives a PCI network interface, before
the slot number.

The name depends on the machine type, not on the guest, so the hypervisor gives
it.  The domain XML asks for i440fx.  There, the predictable naming of systemd
gives C<ensN> for a device in hotplug slot N.  Other machine types give other
names, most often C<enpNsM>.  A hypervisor that builds its guests differently
overrides this.

=head2 nic_names

The names that the two interfaces of a guest get, NAT first.

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

sub nic_slots  { return ( 3, 4 ) }
sub nic_prefix { return 'ens' }

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
    my $domain = $self->_domain($name) or return ();

    my @snaps = eval { $domain->list_all_snapshots() };
    return () unless @snaps;

    my @dated = map { { name => $_->get_name(), created => _snapshot_created($_) } } @snaps;
    return map { $_->{name} }
      sort { $a->{created} <=> $b->{created} or $a->{name} cmp $b->{name} }
      grep { $_->{name} } @dated;
}

# <creationTime> is seconds since the epoch.  A snapshot without one sorts
# first, as the oldest.
sub _snapshot_created {
    my ($snap)    = @_;
    my $xml       = eval { $snap->get_xml_description() } // '';
    my ($created) = $xml =~ m{<creationTime>(\d+)</creationTime>};
    return $created // 0;
}

=head2 snapshot_current_name($domain)

The name of the current snapshot of the domain, or undef if it has none.

=cut

sub snapshot_current_name {
    my ( $self, $name ) = @_;
    my $domain = $self->_domain($name)                or return undef;
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
    my $domain = $self->_domain($name) or die "No such domain $name on " . $self->uri . "\n";

    # libvirt takes a full system snapshot of a running guest, or a disk-only
    # snapshot of a stopped guest, and no other kind.  Any other request is error
    # 84, "live snapshot creation is supported only during full system snapshots".
    my $live = !$opts{disk_only} && $domain->is_active();

    # Set before the stop below, because the stop changes is_active.
    my $resume = $opts{disk_only} && !$opts{leave_down} && $domain->is_active();

    $self->stop_domain($name) if $opts{disk_only};

    my $xml = '<domainsnapshot>';
    $xml .= '<name>' . _xml_escape($snapname) . '</name>' if $snapname;

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
    my $domain = $self->_domain($name)                             or return 0;
    my $snap   = eval { $domain->get_snapshot_by_name($snapname) } or return 0;

    my $ok = eval { $snap->revert_to( Sys::Virt::DomainSnapshot::REVERT_RUNNING() ); 1 };
    warn "Revert of $name to $snapname failed: $@" unless $ok;
    return $ok ? 1 : 0;
}

sub _xml_escape {
    my ($str) = @_;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    return $str;
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

sub supports {
    my ( $self, $feature ) = @_;
    my $needs = $DISK_FEATURE{$feature} or die "No such disk feature as '$feature'\n";

    return $self->{supports}{$feature} //= $self->_meets($needs);
}

# In this order on purpose.  The qemu-img probe runs a command on the
# hypervisor, which is not necessary if libvirt is too old for the option.
sub _meets {
    my ( $self, $needs ) = @_;

    return 0 if $self->libvirt_version < _version_number( $needs->{libvirt} );
    return 0 if $needs->{qemu}     && $self->qemu_version < _version_number( $needs->{qemu} );
    return 0 if $needs->{qemu_img} && !$self->qemu_img_options->{ $needs->{qemu_img} };
    return 1;
}

# Encodes a dotted version the way libvirt does, so that it compares directly
# with what the connection reports.
sub _version_number {
    my ($version) = @_;

    # A character class, not an escape.  split always takes a pattern, so '.'
    # splits on every character, and perlcritic calls m/\./ a substring match.
    my ( $major, $minor, $release ) = split( m/[.]/, $version );
    return ( $major * 1_000_000 ) + ( $minor * 1_000 ) + ( $release // 0 );
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
    return $self->{pool_fstype} if defined $self->{pool_fstype};

    # Quoted by hand, because capture_cmd takes a shell string and the pool path
    # can come from a configuration file.
    ( my $quoted = $self->pool_path ) =~ s/'/'\\''/g;

    my $type = $self->capture_cmd("stat -f -c %T '$quoted' 2>/dev/null") // '';
    chomp $type;

    return $self->{pool_fstype} = $type;
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
my $QCOW2_DEFAULT_CLUSTER = 64 * 1024;
my $QCOW2_LARGE_CLUSTER   = 1024 * 1024;

# The default qemu memory for qcow2 metadata, and the most that we ask for.  Both
# are for each running domain, in host memory that Trog::Hypervisors does not
# count.
my $QCOW2_METADATA_DEFAULT = 32 * 1024 * 1024;
my $QCOW2_METADATA_CAP     = 256 * 1024 * 1024;

# Above this size, the default metadata cache does not cover the whole image.
# qcow2_tuning gives the arithmetic.
my $QCOW2_LARGE_DISK = 128 * 1024 * 1024 * 1024;

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
  <name>@{[ _xml_escape($name) ]}</name>
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

=head2 $hv->disk_layout($volume)

The layout of an existing qcow2 volume, as a hashref with C<cluster_size> in
bytes and C<extended_l2> as 1 or 0.  Undef when there is no such volume or
qemu-img does not answer.

=cut

sub disk_layout {
    my ( $self, $name ) = @_;

    # sudo, -U, and no 2>/dev/null.  The disk is 0600 libvirt-qemu:kvm, so
    # qemu-img needs root to open it.  The guest can be running, and its qemu
    # holds a write lock, so qemu-img also needs -U.  Either failure returns
    # undef, which disk_reusable reads as a disk that cannot be kept.  So the
    # errors stay visible.
    my $path = $self->volume_path($name) or return undef;
    my $json = $self->capture_cmd("sudo qemu-img info -U --output=json '$path'") // q{};
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

    # As root, because libvirt makes the disk 0600 libvirt-qemu:kvm.  Without
    # sudo, qemu-img fails with "Permission denied" and no snapshot.
    return $self->run_sudo( qw{qemu-img snapshot -c}, $snapname, $path ) == 0 ? 1 : 0;
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

    # As root, for the reason that snapshot_disk gives.  A revert that fails
    # without a word leaves the new guest on the filesystem of the old one.
    return $self->run_sudo( qw{qemu-img snapshot -a}, $snapname, $path ) == 0 ? 1 : 0;
}

=head2 $hv->disk_snapshot_names($volume)

The names of all internal snapshots in a volume, in the order that qemu-img
lists them.  An empty list when there is no such volume or no snapshot.

=cut

sub disk_snapshot_names {
    my ( $self, $name ) = @_;

    # sudo and -U, for the reasons that disk_layout gives.  rollback_possible
    # asks this about a running guest.  If qemu-img cannot open the disk, the
    # answer is "no snapshots", and no rollback happens.
    my $path = $self->volume_path($name) or return ();
    my $said = $self->capture_cmd("sudo qemu-img snapshot -l -U '$path'") // q{};

    # After the header, each line starts with a numeric id, and the tag is the
    # second field.
    return map { ( split q{ }, $_ )[1] } grep { m/\A \s* \d+ \s+ \S/ } split m/\n/, $said;
}

=head2 bridge_device

The outbound bridge for the public interface of a guest.

=head2 virbr_device

The libvirt NAT bridge.

=head2 virbr_ip

The address of the hypervisor on the NAT bridge.  The guest fetches its files
from this address and sends its logs to it.

The templates for a guest need these three values.  Each one comes from the
configuration if it is set there.  If not, the method reads it from C<brctl>
or C<ip> on the hypervisor, and dies if it finds nothing.  The C<brctl> guess
is sometimes wrong, so set the value when it is.

=cut

sub bridge_device {
    my ($self) = @_;
    return $self->{bridge_device} if defined $self->{bridge_device};

    my $device = $self->capture_cmd(q{brctl show | grep -vP 'vnet|virbr' | tail -n1 | awk '{print $1}'});
    chomp $device if defined $device;
    die "Could not determine outbound bridge device on " . $self->uri . "!\n" . "Set bridge_device in this hypervisor's block of hypervisors.conf, or in provision.conf if there is no hypervisors.conf.\n"
      unless $device;

    return $self->{bridge_device} = $device;
}

sub virbr_device {
    my ($self) = @_;
    return $self->{virbr_device} if defined $self->{virbr_device};

    my $device = $self->capture_cmd(q{brctl show | grep virbr | tail -n1 | awk '{print $1}'});
    chomp $device if defined $device;
    die "Could not determine libvirt network device on " . $self->uri . "!\n" . "Set virbr_device in this hypervisor's block of hypervisors.conf, or in provision.conf if there is no hypervisors.conf.\n"
      unless $device;

    return $self->{virbr_device} = $device;
}

sub virbr_ip {
    my ($self) = @_;
    return $self->{virbr_ip} if defined $self->{virbr_ip};

    my $device = $self->virbr_device;
    my $ip     = $self->capture_cmd("ip addr show dev $device | grep inet | head -n1 | awk '{print \$2}'");
    die "Could not determine IP address for $device\n" unless $ip;
    chomp $ip;
    $ip =~ s{/\d+\z}{};

    return $self->{virbr_ip} = $ip;
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

Dies if libvirt does not answer, because a guest must not go on a hypervisor
that cannot give these values.

=cut

sub capacity {
    my ($self) = @_;
    return $self->{capacity} if $self->{capacity};

    my $node    = $self->vmm->get_node_info();
    my @domains = $self->vmm->list_all_domains();

    my ( $memory_committed, $cpus_committed ) = ( 0, 0 );
    foreach my $domain (@domains) {
        my $info = eval { $domain->get_info() } or next;

        # maxMem is the most memory the guest can use, so it counts in full.
        $memory_committed += ( $info->{maxMem}    // 0 ) / 1024;
        $cpus_committed   += ( $info->{nrVirtCpu} // 0 ) if eval { $domain->is_active() };
    }

    my $memory_mb        = ( $node->{memory} // 0 ) / 1024;
    my $cpus             = $node->{cpus} // 0;
    my $cpus_allocatable = $cpus * $self->cpu_overcommit;

    return $self->{capacity} = {
        memory_mb        => $memory_mb,
        memory_committed => $memory_committed,
        memory_free      => $memory_mb - $memory_committed - $self->reserve_memory,
        cpus             => $cpus,
        cpus_allocatable => $cpus_allocatable,
        cpus_committed   => $cpus_committed,
        cpus_free        => $cpus_allocatable - $cpus_committed - $self->reserve_cpus,
        disk_free        => $self->pool_free() - $self->reserve_disk,
        guests           => scalar @domains,
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

=cut

sub prepare_host {
    my ( $self, $virtiofs ) = @_;

    $self->mkpath( $self->pool_path )
      or die "Could not create storage pool dir " . $self->pool_path . " on the hypervisor";

    return 1 if $self->file_exists('/usr/libexec/virtiofs-better');

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
hypervisor, the NAT lease routes only from the hypervisor.  So the result is the
first address in C<ips> in the configuration, the bridged static address of the
guest.  Dies if C<ips> is not set.

=cut

sub guest_ssh_ip {
    my ( $self, $config, $lease_ip ) = @_;
    return $lease_ip if $self->is_local;

    my ($ip) = grep { $_ } $config->param('ips');
    die "Provisioning against a remote hypervisor (" . $self->uri . ") requires the guest to have a\n" . "routable address: set 'ips' in provision.conf.  The libvirt NAT lease (" . ( $lease_ip // 'none' ) . ") is only\nreachable from the hypervisor itself.\n"
      unless $ip;
    return $ip;
}

=head2 @names = $hv->preflight_checks(), $hv->preflight_notes()

The names of the checks and notes that C<bin/preflight> runs on this backend, in
order.  L<Trog::HV/PREFLIGHT> describes what each one returns.

=cut

sub preflight_checks { return qw{check_reachable check_passwordless_sudo check_iso_builder check_rsync check_transfer_ip check_fetch_sources check_libvirt check_sys_virt_in_step check_pool_writable check_config} }
sub preflight_notes  { return qw{note_libguestfs note_swtpm note_stale_image note_apt_mirror note_log_destination note_pool_quota note_plaintext_secrets} }

=head2 $result = $hv->check_reachable()

Passes on a local hypervisor, or when C<whoami> runs over ssh on a remote one.

=cut

sub check_reachable {
    my ($self) = @_;

    return $self->_verdict( 1, 'The hypervisor is this machine', q{} ) if $self->is_local;

    my $whoami = eval { $self->capture_cmd('whoami') };
    chomp $whoami if defined $whoami;

    return $self->_verdict( 1, "Reached " . $self->ssh_target . " as $whoami", q{} )
      if $whoami;

    return $self->_verdict( 0, 'Cannot reach ' . $self->describe, <<"FIX" );
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
    return $self->_verdict( 0, 'Could not ask the hypervisor for its NAT bridge', <<"FIX" ) unless $virbr;
$@
Guests are built on that network and fetch their payload across it, so this has
to answer before anything can be worked out about reaching them.
FIX

    my $ours = eval { Trog::Local->new()->transfer_ip($virbr) };
    return $self->_verdict( 1, "Guests fetch their payload from $ours", q{} ) if $ours;

    return $self->_verdict( 0, "No address of ours is reachable from a guest on $virbr", <<"FIX" );
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

A grant for the lease helper alone is enough to build a guest.  The other root
steps are the first install of F<virtiofs-better> and the C<qemu-img> calls for
the C<trog-pristine> snapshot and its revert.  Without those, a guest builds,
but a rebuild cannot keep its disk.  C<sudo -n true>
fails for the narrow grant too, so this also asks C<sudo -n -l> about the lease
helper.

=cut

my $LEASE_HELPER = '/usr/lib/libvirt/libvirt_leaseshelper';

sub check_passwordless_sudo {
    my ($self) = @_;

    if ( $self->run_cmd(qw{sudo -n true}) == 0 ) {
        my $allowed = eval { $self->capture_cmd('sudo -n -l 2>/dev/null') } // q{};
        my $whole   = $allowed =~ m/NOPASSWD:\s*ALL/;

        return $self->_verdict( 1, 'Passwordless sudo, for everything', q{} ) if $whole;
        return $self->_verdict( 1, 'Passwordless sudo',                 q{} );
    }

    # A narrow grant is correct for an account that builds guests unattended.
    return $self->_verdict( 1, "Passwordless sudo for $LEASE_HELPER, which is what a provision needs", <<"FIX" )
A rebuild that keeps the disk of a guest will not work for this account, which
is deliberate at this level.  Widen the grant if you need it.
FIX
      if $self->run_cmd( qw{sudo -n -l}, $LEASE_HELPER ) == 0;

    my $user   = $self->ssh_user // 'you';
    my $target = $self->is_local ? 'this machine' : $self->ssh_host;

    return $self->_verdict( 0, "No passwordless sudo for $user on $target", <<"FIX" );
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
-- or a write into the storage pool:

    echo '$user ALL=(root) NOPASSWD: $LEASE_HELPER' | sudo tee /etc/sudoers.d/90-$user
    sudo usermod -aG libvirt $user

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
    return $self->_verdict( 0, 'Could not work out where the storage pool is', <<'FIX' ) unless $path;
libvirt looks a pool up by name, so pool_name in hypervisors.conf has to name one
this hypervisor has, or pool_path has to say outright where it is:

    virsh pool-list --all
FIX

    # The probe of pool_takes_direct_io, without O_DIRECT.
    my $probe = "$path/.writable-probe.$$";
    return $self->_verdict( 1, "Storage pool $path takes a write", q{} )
      if $self->run_cmd( 'sh', '-c', 'touch "$1" 2>/dev/null && rm -f "$1"', 'sh', $probe ) == 0;

    return $self->_verdict( 0, "Storage pool $path is not writable on " . $self->describe, <<"FIX" );
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
    return $self->_verdict( 1, "Cloud-init seed builder: $maker", q{} ) if $maker;

    return $self->_verdict( 0, 'No ISO builder on the hypervisor', <<'FIX' );
cloud-init reads its configuration off a small ISO, and something has to make
it:

    sudo apt install xorriso
FIX
}

=head2 $result = $hv->check_libvirt()

Passes when libvirt answers on the connection URI.

=cut

sub check_libvirt {
    my ($self) = @_;

    my $version = eval { $self->vmm->get_library_version() };
    return $self->_verdict( 1, 'libvirt answers, running ' . _version_string($version), q{} ) if $version;

    return $self->_verdict( 0, 'libvirt did not answer', <<"FIX" );
$@
The URI is @{[ $self->uri ]}.  Check libvirtd is running there and that the user
is in the libvirt group.
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
    return $self->_verdict( 0, 'Could not ask the hypervisor its libvirt version', <<'FIX' ) unless $remote;
libvirt did not answer, so this could not be checked.  Fix that first; the
answer is above.
FIX

    my $there = _version_string($remote);
    my $here  = Sys::Virt->VERSION;

    my ($here_mm)  = $here  =~ m/\A(\d+\.\d+)/;
    my ($there_mm) = $there =~ m/\A(\d+\.\d+)/;

    return $self->_verdict( 1, "Sys::Virt $here matches libvirt $there on the hypervisor", q{} )
      if defined $here_mm && defined $there_mm && $here_mm eq $there_mm;

    return $self->_verdict( 0, "Sys::Virt $here here, libvirt $there on the hypervisor", <<"FIX" );
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

Fails when the storage pool is as large as its filesystem, which means that no
quota limits it.  Passes when there is no pool yet.

libvirt does not count what anyone allocates.  On the system URI, every guest
runs as libvirt-qemu, so a disk quota has no UID to apply to.  Only a filesystem
with a limit under the pool limits the guests.  Without one, the pool can fill
the root filesystem of the hypervisor.  This is a note and not a check, because
most hypervisors have no such limit.

=cut

sub note_pool_quota {
    my ($self) = @_;

    # Not through pool(), which defines and starts a pool it cannot find.  A
    # check must not build anything.
    my $name = $self->pool_name;
    my $info = eval { $self->vmm->get_storage_pool_by_name($name)->get_info() } or return { ok => 1 };

    # The last line is the mount, and with -B1 its second field is the size in
    # bytes.
    my $path    = $self->pool_path;
    my $said    = eval { $self->capture_cmd("df -B1 '$path' 2>/dev/null | tail -n1") } // q{};
    my ($bytes) = $said =~ m/\A\S+\s+(\d+)\s/;

    # The pool is a directory, and libvirt reports the statvfs size of its
    # filesystem.  A size within a gigabyte of the filesystem is no limit.
    return { ok => 1 }
      if !defined $bytes || abs( $bytes - ( $info->{capacity} // 0 ) ) >= 1_073_741_824;

    return {
        ok   => 0,
        what => sprintf( 'The %s pool has no quota: its %.1fGB is all of %s', $name, ( $info->{capacity} // 0 ) / 1_073_741_824, $path ),
        fix  => <<"FIX" };
Guests built here are limited by nothing but the filesystem, and by
reserve_disk in hypervisors.conf -- which is this tool asking itself for
permission, and says nothing to anybody driving virsh directly.

To make it real, give the pool a filesystem of its own with a limit on it:

    zfs create -o quota=500G tank/vm-disks/$name

then name both halves in hypervisors.conf, because libvirt looks a pool up by
name and a pool_path beside an existing pool's name is silently ignored:

    pool_path = /tank/vm-disks/$name
    pool_name = $name

This matters most for a hypervisor an unattended runner can build on.  See
QUOTAS in Provisioner::Recipe::trogrunner.
FIX
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
    my @domains = grep { !m/\A_/ } sort keys %$conf;

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

# Turns a packed libvirt version, major * 1000000 + minor * 1000 + release, into
# dotted form.  libvirt_version is a different method, which asks the connection.
sub _version_string {
    my ($packed) = @_;
    return sprintf '%d.%d.%d', int( $packed / 1000000 ), int( $packed / 1000 ) % 1000, $packed % 1000;
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

A rebuilt guest keeps its MAC, which comes from its name.  But it is a new DHCP
client, so dnsmasq gives it a new address and keeps the old lease.  Without the
release, each rebuild holds one more address in the NAT range.  Also, the wait
in C<provision_guest> finds the old lease and stops before the new guest asks.

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

    print "\nDefined and started; $domain should come up at $address\n";

    return $address;
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

=head1 SEE ALSO

L<Sys::Virt>

=cut

1;
