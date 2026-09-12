package Trog::HV::Libvirt;

#ABSTRACT: the libvirt backend: domains, storage pools and the facts of a qemu host.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';
use parent 'Trog::HV';

use Sys::Virt();
use Digest::SHA();
use URI();
use URI::Split();

use Trog::Local();
use Provisioner::Cookbook();

=head1 NAME

Trog::HV::Libvirt - the libvirt backend: domains, storage pools and the facts of
a qemu host

=head1 SYNOPSIS

    # Not built directly.  Trog::HV chooses a backend and hands one back.
    my $hv = Trog::HV->new(uri => 'qemu+ssh://root@hv1.example.net/system');

    $hv->annihilate_domain('vm.example.test');
    print $hv->pool_path, "\n";

=head1 DESCRIPTION

A hypervisor we reach by a libvirt connection URI.  Everything here goes through
L<Sys::Virt>, which speaks every transport a URI can name and needs no shell to
do it -- there is no shelling out to C<virsh>, and no assumption that the
hypervisor's libvirt is reachable any way other than the URI we were given.

What is I<not> here is in L<Trog::HV>: the singleton, the per-domain directory,
and the placement arithmetic, none of which is particular to libvirt.

Two things about this backend are load-bearing above it.  The hypervisor is a
machine we can get a shell on, and its storage is a libvirt pool on that
machine's filesystem.  A backend without either cannot be a drop-in for this one.

=head1 CLASS METHODS

=cut

our $DEFAULT_URI = 'qemu:///system';

# Transports over which we can also get a shell on the HV.
my %SSH_TRANSPORT = map { $_ => 1 } qw{ssh libssh libssh2};

=head2 config_keys

The F<hypervisors.conf> keys this backend reads, and the constructor options
they land in.  C<libvirt_uri> is what marks a block as one of ours.

=cut

sub config_keys {
    return (
        uri => 'libvirt_uri',
        map { $_ => $_ } qw{pool_path pool_name domain_dir bridge_device virbr_device partition},
    );
}

=head2 build(%given)

Build one.  Called by L<Trog::HV/candidate>, which has already decided this is
the backend the options are asking for.

The URI defaults to C<qemu:///system>, and C<explicit> records whether it was
actually asked for -- when it was not, we let libvirt resolve its own default
connection exactly as C<virsh> with no C<-c> would.

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

    # A remote hypervisor we can't get a shell on is only half usable, and the
    # half that's missing (files, bridge detection) isn't optional.  Say so now
    # rather than three minutes into a provision run.
    die "The hypervisor at $uri is remote, but its transport gives us no shell.\n" . "Use an ssh transport instead, e.g. qemu+ssh://root\@" . ( $self->{host} // 'hypervisor' ) . "/system, so we can reach its filesystem.\n"
      if !$self->is_local && !defined $self->ssh_host;

    return $self;
}

# A libvirt connection URI is a URI: driver[+transport]://[user@][host][:port]/path
#
# L<URI> knows nothing about the driver+transport scheme, so it hands back a
# URI::_foreign with no authority accessors.  Split it generically instead and
# re-parse the authority under a scheme URI does understand, which gets us
# userinfo, bracketed IPv6 and ports without a regex of our own.
sub _parse_uri {
    my ($uri) = @_;

    my ( $scheme, $authority, $path ) = URI::Split::uri_split($uri);
    return undef unless defined $scheme && length $scheme;

    my ( $driver, $transport ) = split( quotemeta('+'), $scheme, 2 );
    return undef unless defined $driver && length $driver;

    my $server = ( defined $authority && length $authority ) ? URI->new("ssh://$authority") : undef;

    return {
        driver    => $driver,
        transport => $transport,
        user      => $server                                                      ? $server->user : undef,
        host      => ( $server && defined $server->host && length $server->host ) ? $server->host : undef,
        port      => $server                                                      ? $server->port : undef,
        path      => $path,
    };
}

=head1 IDENTITY

=head2 uri

The libvirt connection URI, defaulted to C<qemu:///system>.

=head2 explicit

Whether the URI was actually asked for, as opposed to defaulted.  When it
wasn't, we let libvirt resolve its own default connection exactly as C<virsh>
with no C<-c> would.

=head2 is_local

True when the hypervisor is this very machine, i.e. the historical behavior.

=head2 slug

A filesystem-safe token identifying this hypervisor.

=cut

sub uri { return $_[0]->{uri} }

sub is_local {
    my ($self) = @_;
    return !defined $self->{host};
}

sub slug {
    my ($self) = @_;
    my $slug = $self->{uri};
    $slug =~ s/[^A-Za-z0-9]+/_/g;
    $slug =~ s/\A_+|_+\z//g;
    return $slug;
}

=head2 ssh_host, ssh_user, ssh_port, ssh_target

Where to ssh to in order to run something on the hypervisor, all inferred from
the connection URI.  C<ssh_host> is undef when the transport can't give us a
shell, which C<new> refuses to build in the first place.  C<ssh_port> falls back
to 22, the way any other ssh client would.

=cut

sub ssh_host {
    my ($self) = @_;
    return undef unless defined $self->{host};

    # A bare qemu://host/system speaks libvirt's native remote transport, but
    # that still tunnels over ssh by default, so treat it as ssh-able too.
    return $self->{host} if !defined $self->{transport} || $SSH_TRANSPORT{ $self->{transport} };
    return undef;
}

sub describe { return 'the hypervisor at ' . $_[0]->uri }

=head1 PATHS

=head2 pool_path

Where the storage pool keeps its volumes, asked of libvirt rather than assumed:
we delete things out of this path, and a pool somebody made somewhere else is
not a reason to be wrong about it.  Falls back to F</opt/terraform/disks>, which
is where the volumes on a hypervisor built by the old tool actually are.

=head2 pool_name

Which storage pool this hypervisor's guests are built in.  C<tf_disks> unless
F<hypervisors.conf> says otherwise.

Configurable because it is the only way C<pool_path> can mean anything: libvirt
looks a pool up by name, so a path given beside the name of a pool that already
exists somewhere else is ignored, silently, and every volume lands where the
existing pool points.  Giving a hypervisor its own pool -- on a filesystem with
a quota on it, which is the only quota libvirt guests can be held to -- is
naming both.

=head2 partition

The cgroup partition its guests are placed in, or undef for libvirt's own
default of C</machine>.  Sets nothing: it puts every guest built here in one
systemd slice, which is where an operator can then cap CPU and I/O for the lot
of them at once.

=cut

sub pool_name { return $_[0]->{pool_name} // 'tf_disks' }
sub partition { return $_[0]->{partition} }

sub pool_path {
    my ($self) = @_;
    return $self->{pool_path} if defined $self->{pool_path};

    return $self->{_pool_path} //= ( $self->pool_target( $self->pool_name ) // '/opt/terraform/disks' );
}

=head2 pool_target($name)

Where an existing storage pool keeps its volumes, straight out of libvirt, or
undef if there is no such pool to ask about.

=cut

sub pool_target {
    my ( $self, $name ) = @_;
    $name //= $self->pool_name;

    my $xml = eval {
        my $vmm  = $self->vmm;
        my $pool = $vmm->get_storage_pool_by_name($name);
        $pool->get_xml_description();
    } or return undef;

    my ($path) = $xml =~ m{<target>.*?<path>([^<]+)</path>}s;
    return $path;
}

=head1 LIBVIRT

All of this goes through L<Sys::Virt>, which talks the connection URI's
transport itself.  There is no shelling out to C<virsh> and no assumption that
the hypervisor's libvirt is reachable any way other than the URI we were given.

=head2 vmm

The L<Sys::Virt> connection, opened on first use and kept.

=cut

sub vmm {
    my ($self) = @_;
    return $self->{vmm} if $self->{vmm};

    # An unasked-for URI means "whatever libvirt would pick", which is what
    # virsh with no -c did before any of this was configurable.
    my $uri = $self->explicit ? $self->uri : '';
    $self->{vmm} = eval { Sys::Virt->new( uri => $uri, readonly => 0 ) }
      or die "Could not connect to libvirt at " . $self->uri . ": $@\n";
    return $self->{vmm};
}

# Domain lookups throw when the domain is simply absent, which is not an error
# anywhere we ask.  Opening the connection happens outside the eval, so a
# hypervisor we can't reach at all doesn't get reported as "no such domain".
sub _domain {
    my ( $self, $name ) = @_;
    my $vmm = $self->vmm;
    return eval { $vmm->get_domain_by_name($name) };
}

=over 4

=item C<domain_exists($name)>

=item C<domain_is_running($name)>

=item C<domain_xml($name)>

The domain's XML description, or undef if there is no such domain.

=back

=cut

=head2 guest_names

Every domain libvirt knows about here, defined or running.

=cut

sub guest_names {
    my ($self) = @_;
    return map { $_->get_name } $self->vmm->list_all_domains();
}

sub domain_exists     { return defined $_[0]->_domain( $_[1] )                      ? 1 : 0 }
sub domain_is_running { my $d = $_[0]->_domain( $_[1] ); return $d && $d->is_active ? 1 : 0 }

sub domain_xml {
    my ( $self, $name ) = @_;
    my $domain = $self->_domain($name) or return undef;
    return $domain->get_xml_description();
}

=head2 annihilate_domain($name)

Stop and undefine a domain, nvram and all, and don't complain if it was already
gone or already off.  Which is
the only reason we do.

Returns true if there was something there to remove.

=cut

sub annihilate_domain {
    my ( $self, $name ) = @_;
    my $domain = $self->_domain($name) or return 0;

    # A domain that is already shut off can't be destroyed, and that's the
    # normal case here rather than a problem.
    eval { $domain->destroy() };
    eval {
        $domain->undefine( Sys::Virt::Domain::UNDEFINE_NVRAM() | Sys::Virt::Domain::UNDEFINE_SNAPSHOTS_METADATA() );
        1;
    } or do {

        # Older libvirt without nvram support for this domain type.
        eval { $domain->undefine() };
    };
    return 1;
}

=head2 lease_ip($network, %opts)

The address libvirt has leased on C<$network>, usually C<default>.

Pass C<mac> and it asks dnsmasq for that interface's lease and nothing else,
which is exact.  Pass C<hostname> and it matches on what the guest called
itself, which is a substring match and can be fooled: a guest named
C<vm.example.test> matches a lease belonging to C<sub.vm.example.test>.  Prefer
the MAC; C<guest_mac> exists so there always is one.

Where several leases match, the one that expires last, which is the one granted
or renewed most recently.  A MAC can hold several: a guest rebuilt under the same
name gets a new address while its old lease stays on file until it runs out.

=cut

sub lease_ip {
    my ( $self, $network, %opts ) = @_;
    my ($newest) = $self->lease_ips( $network, %opts );
    return $newest;
}

=head2 @ips = lease_ips($network, %opts)

Every address leased on C<$network> that matches, newest first, taking the same
options as C<lease_ip>.  For when all of them are wanted: the leases a rebuilt
guest's predecessors left behind, to release.

=cut

sub lease_ips {
    my ( $self, $network, %opts ) = @_;

    my $vmm = $self->vmm;
    my $net = eval { $vmm->get_network_by_name($network) } or return ();

    # get_dhcp_leases filters by MAC on the far side, so with one we ask a
    # precise question rather than sifting the answer.
    my @leases = eval { $net->get_dhcp_leases( $opts{mac} ) };

    my @ips;
    foreach my $lease ( sort { ( $b->{expirytime} // 0 ) <=> ( $a->{expirytime} // 0 ) } @leases ) {
        next unless defined $lease->{ipaddr} && length $lease->{ipaddr};
        next
          if defined $opts{hostname}
          && !( defined $lease->{hostname} && $lease->{hostname} =~ m/\Q$opts{hostname}\E/ );
        next if defined $opts{exclude} && $lease->{ipaddr} eq $opts{exclude};
        push @ips, $lease->{ipaddr};
    }
    return @ips;
}

=head2 release_dhcp_lease($ip, $bridge)

Drop a stale lease so the table doesn't fill up and gum everything else.

This is the one libvirt operation we still shell out for: libvirt exposes DHCP
leases read-only (C<virNetworkGetDHCPLeases> has no counterpart that deletes
one), so releasing a lease means poking dnsmasq through libvirt's own lease
helper on the hypervisor.

=cut

sub release_dhcp_lease {
    my ( $self, $ip, $bridge ) = @_;
    return 0 unless defined $ip && length $ip;
    $bridge //= $self->virbr_device;

    my ($helper) = grep { $self->file_exists($_) } qw{/usr/lib/libvirt/libvirt_leaseshelper /usr/libexec/libvirt_leaseshelper};
    unless ($helper) {
        warn "No libvirt lease helper found on the hypervisor, leaving the lease for $ip alone\n";
        return 0;
    }

    return $self->run_sudo( "VIR_BRIDGE_NAME=$bridge", $helper, qw{del ip}, $ip ) == 0 ? 1 : 0;
}

=head2 eject_cdrom($domain, $target)

Yank the cloud-init ISO back out, so the guest doesn't try to boot it again on
its next start.  C<$target> defaults to C<sda>, which is where the domain XML
puts it.

Call this only once the guest says cloud-init has finished.  The seed has to
stay in the drive for as long as cloud-init might want to read it; taking it
out earlier leaves the guest with no user, no keys and no netplan.

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

=head2 nuke_pool($name)

Tear a storage pool down completely -- stop it, delete its contents, forget it
-- and remove its directory from the hypervisor.  For a pool that has got
itself into a state nothing else will get it out of.

=cut

sub nuke_pool {
    my ( $self, $name ) = @_;

    # The directory goes first: pool-delete on a pool whose backing store is
    # already gone is a no-op, but the reverse leaves files libvirt still owns.
    $self->run_sudo( qw{rm -rf}, $self->pool_path );

    my $vmm  = $self->vmm;
    my $pool = eval { $vmm->get_storage_pool_by_name($name) };
    unless ($pool) {
        print "No storage pool named $name on " . $self->uri . ", nothing to nuke.\n";
        return 0;
    }

    foreach my $step (qw{destroy delete undefine}) {
        eval { $pool->$step(); 1 } or warn "pool $step failed for $name: $@";
    }
    return 1;
}

=head1 BUILDING THINGS

Everything terraform used to do, done against libvirt directly.

Terraform was never a good fit here.  Its model was that it owned the world and
can rebuild it; ours is that the hypervisor owns the world and we add one guest
to it.  Reconciling those cost a state file per hypervisor, import blocks for
things it did not create, C<ignore_changes> for attributes the provider would
not report back, and a provider that cannot import a volume at all.  Defining
the XML ourselves is less code than the machinery that was holding terraform's
opinion at bay.

=head2 pool($name)

The storage pool object, made if it is not there yet: defined, started, and set
to start with the host.  C<$name> defaults to L</pool_name>.

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
        eval { $pool->build( Sys::Virt::StoragePool::BUILD_NEW() ) };
        $pool->set_autostart(1);
    }

    eval { $pool->create() } unless $pool->is_active();
    return $self->{_pools}{$name} = $pool;
}

=head2 volume($name, $pool)

A volume by name, or undef when the pool has no such volume.

=head2 volume_path($name, $pool)

Where that volume's file actually is, which is what a domain's disk needs.

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

The base image every guest's disk is layered on, downloaded onto the
hypervisor if it is not there yet.  Returns its path.

The download is the one thing here libvirt cannot do for us -- it has no notion
of fetching a URL -- so it is a curl on the far side, into the pool directory,
followed by a refresh so libvirt notices.

=cut

sub base_image {
    my ( $self, $url, $name ) = @_;
    $name //= 'baseimage-qcow2';

    my $path = $self->volume_path($name);
    return $path if $path;

    die "No image URL configured, and no $name in the pool to fall back on\n"
      unless defined $url && length $url;

    $path = $self->pool_path . "/$name";
    print "Fetching the base image from $url\n";

    # To a partial name first: a half-downloaded file that libvirt has already
    # noticed is worse than no file at all.
    my $partial = "$path.partial";
    $self->run_cmd( qw{curl -fL --retry 3 -o}, $partial, $url ) == 0
      or die "Could not fetch $url onto " . $self->describe . "\n";

    $self->run_cmd( 'mv', $partial, $path ) == 0 or die "Could not put the base image in place\n";
    $self->refresh_pool();

    return $self->volume_path($name) // $path;
}

=head2 create_disk($name, %opts)

A qcow2 volume backed by the base image, made if it is not already there.
C<backing> is the path to lay it over and C<capacity> its size in bytes.
Returns the path.

How it is laid out inside comes from C<qcow2_tuning>, which is where the
reasoning lives.  Nothing it decides is retrofittable: cluster size and
subcluster allocation are properties of the image as created, so a disk that
already exists is left exactly as it is -- it is a guest's filesystem.

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

    return $volume->get_path();
}

=head2 delete_volume($name, $pool)

Remove a volume, and say whether there was one to remove.

=head2 refresh_pool($name)

Make libvirt look at the pool directory again, for when something has appeared
in it that libvirt did not put there.

=cut

sub delete_volume {
    my ( $self, $name, $pool ) = @_;
    my $volume = $self->volume( $name, $pool ) or return 0;
    eval { $volume->delete(0); 1 } or do { warn "Could not delete the volume $name: $@"; return 0 };
    return 1;
}

sub refresh_pool {
    my ( $self, $name ) = @_;
    eval { $self->pool($name)->refresh() };
    return 1;
}

=head2 cloudinit_iso($domain, %files)

Build the cloud-init seed ISO on the hypervisor and put it in the pool.

C<%files> are the NoCloud file names and their contents -- C<user-data>,
C<meta-data>, C<network-config>.  The volume label has to be C<cidata> or
cloud-init will not look at it.

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

    # -volid cidata is not decoration: NoCloud finds its seed by that label.
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

Whichever of C<xorriso>, C<genisoimage> or C<mkisofs> the hypervisor has.

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

Define a domain from XML and start it.  Set C<autostart> to have it come back
with the host, which is what every guest here wants.

=cut

sub define_domain {
    my ( $self, $xml, %opts ) = @_;

    my $domain = $self->vmm->define_domain($xml);
    eval { $domain->set_autostart(1) } if $opts{autostart} // 1;
    eval { $domain->create() } unless $domain->is_active();

    return $domain;
}

=head1 GUEST IDENTITY

=head2 guest_mac($domain, $index)

A MAC address for one of a guest's interfaces, derived from its name so that it
is the same every time.

Letting libvirt generate them means a rebuilt guest arrives with new MACs: it
takes a new DHCP lease while the old one sits in the table until it expires,
and any network configuration that matched on a name rather than an address
has to guess which interface is which.  Deriving them removes both problems --
the lease is the same lease, and the configuration can say exactly which
interface it means.

C<52:54:00> is the QEMU/KVM prefix; the rest is the first three bytes of a
digest of the domain and the interface index.  Three bytes is not a lot, so
two guests colliding is possible in principle -- at a few thousand of them.

=head2 nic_slots

Which PCI slots the two interfaces sit in, in order.  Pinned rather than left to
allocation order, because systemd names a PCI NIC after its hotplug slot: left
alone, the names move whenever the device list does.

=head2 nic_prefix

What a guest here calls a PCI network interface, before the slot number.

A property of the machine type rather than of the guest, which is why it is
asked of the hypervisor rather than assumed by whatever is writing a network
configuration.  The domain XML asks for i440fx, where systemd's predictable
naming gives C<ensN> for a device in hotplug slot N.  Another topology gives
another scheme -- C<enpNsM> is the common one, and some emulated models are
stranger still -- so a hypervisor that builds its guests differently overrides
this.

=head2 nic_names

The names a guest's two interfaces end up with, NAT first.

A prediction rather than a decision: cloud-init matches each interface on its
MAC, which is the one thing about it we choose and the guest cannot disagree
with, and renames it to the name it was given.  So a guest whose kernel names
things some other way still gets the right configuration on the right card, and
this is only what they are called afterwards.

=cut

sub guest_mac {
    my ( $self, $domain, $index ) = @_;
    $index //= 0;

    my $digest = Digest::SHA::sha256_hex("$domain/$index");
    return join( ':', qw{52 54 00}, $digest =~ m/\A(..)(..)(..)/ );
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

Every snapshot the domain has, oldest first.  libvirt hands them back in no
particular order, so they get sorted by creation time here -- C<restore
--latest> and C<--oldest> mean nothing otherwise.

=head2 snapshot_current_name($domain)

The name of the domain's current snapshot, or undef if it has none.

=head2 create_snapshot($domain, $name)

Take a live atomic snapshot.  C<$name> may be undef, in which case libvirt names
it after the current time.  Returns true on success.

=head2 revert_snapshot($domain, $name)

Revert to a named snapshot and leave the domain running.  Returns true on
success.

=cut

sub snapshot_names {
    my ( $self, $name ) = @_;
    my $domain = $self->_domain($name) or return ();

    my @snaps = eval { $domain->list_all_snapshots() };
    return () unless @snaps;

    my @dated = map { { name => $_->get_name(), created => _snapshot_created($_) } } @snaps;
    return map { $_->{name} }
      sort { $a->{created} <=> $b->{created} or $a->{name} cmp $b->{name} }
      grep { defined $_->{name} && length $_->{name} } @dated;
}

# <creationTime> is seconds since the epoch.  A snapshot without one sorts to
# the front, which is where an unknown age belongs.
sub _snapshot_created {
    my ($snap)    = @_;
    my $xml       = eval { $snap->get_xml_description() } // '';
    my ($created) = $xml =~ m{<creationTime>(\d+)</creationTime>};
    return $created // 0;
}

sub snapshot_current_name {
    my ( $self, $name ) = @_;
    my $domain = $self->_domain($name)                or return undef;
    my $snap   = eval { $domain->current_snapshot() } or return undef;
    return $snap->get_name();
}

sub create_snapshot {
    my ( $self, $name, $snapname ) = @_;
    my $domain = $self->_domain($name) or die "No such domain $name on " . $self->uri . "\n";

    my $xml = '<domainsnapshot>';
    $xml .= '<name>' . _xml_escape($snapname) . '</name>' if defined $snapname && length $snapname;
    $xml .= '</domainsnapshot>';

    my $flags = Sys::Virt::DomainSnapshot::CREATE_ATOMIC();

    # LIVE only means anything for a running domain, and libvirt rejects it for
    # one that isn't.
    $flags |= Sys::Virt::DomainSnapshot::CREATE_LIVE() if $domain->is_active();

    my $ok = eval { $domain->create_snapshot( $xml, $flags ); 1 };
    warn "Snapshot of $name failed: $@" unless $ok;
    return $ok ? 1 : 0;
}

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

The network layout the guest templates need.  Each is autodetected on the
hypervisor unless the config pinned it, because C<brctl show | tail -n1> guesses
wrong often enough to be worth overriding.

=head2 bridge_device

The outbound bridge the guest's public interface attaches to.

=head2 virbr_device

The libvirt NAT bridge.

=head2 virbr_ip

The hypervisor's address on that NAT bridge, which is what the guest scp's from
and ships its logs to.

=head2 has_tpm

Whether guests built here should be given a TPM.

Both halves have to be true.  C<swtpm> has to be installed, because the guest's
TPM is emulated -- a process per domain, and libvirt cannot start one that is not
there.  And the hypervisor has to have a real TPM of its own, which is the part
that is not obvious.

An emulated TPM keeps its state in a file on the hypervisor.  A guest that seals
a key to it has sealed that key to a file sitting next to its own disk image,
which is not sealing it to anything: whoever takes the disk takes the TPM with
it.  That is worth having where the hypervisor's own disk is protected by
hardware, and worth nothing where it is not -- and offering a guest a TPM that
cannot keep a secret is worse than offering none, because something on the guest
will use it and believe it.

So: hardware here, or nothing there.

=cut

sub has_tpm {
    my ($self) = @_;
    return $self->{has_tpm} if defined $self->{has_tpm};

    # tpmrm0 rather than tpm0: the resource manager is what anything on a modern
    # kernel actually opens, and its absence on a machine that has tpm0 means the
    # kernel did not bring the TPM up properly anyway.
    my $answer = $self->capture_cmd(q{test -c /dev/tpmrm0 && command -v swtpm > /dev/null && echo yes});
    chomp $answer if defined $answer;

    return $self->{has_tpm} = ( ( $answer // '' ) eq 'yes' ) ? 1 : 0;
}

=head2 libvirt_version

=head2 qemu_version

What the hypervisor is running, encoded the way libvirt encodes a version:
C<major * 1_000_000 + minor * 1_000 + release>.  Both are asked of the
connection rather than of this machine, so a remote hypervisor answers for
itself and a fleet of mixed vintages gets a different answer per machine.

Zero when the connection will not say.  Every capability check below reads that
as "assume not", so a hypervisor we cannot interrogate gets the plain domain it
would have got before any of this, rather than XML it may refuse.

=cut

sub libvirt_version {
    my ($self) = @_;
    return $self->{libvirt_version} //= eval { $self->vmm->get_library_version() } || 0;
}

sub qemu_version {
    my ($self) = @_;
    return $self->{qemu_version} //= eval { $self->vmm->get_version() } || 0;
}

# Every disk tuning knob we know how to emit, and what it takes to accept one.
#
# The numbers are the ones libvirt's own formatdomain and formatstorage
# documentation gives for that attribute -- so this table can be checked against
# the documentation rather than against a changelog, and a wrong entry is a
# thing somebody can look up.
#
# libvirt and qemu are asked separately because they are separate failures.
# XML libvirt cannot parse is a domain that will not define, and we find out at
# once.  XML libvirt parses and passes to a qemu that has no such feature is a
# domain that defines and then will not start, which is found out later and
# somewhere less convenient.
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

Whether this hypervisor will take one of the disk tuning knobs named in
C<%DISK_FEATURE> above.  Memoised, since a build asks the same handful of
questions once per disk.

C<cache> is not in the table: every libvirt that can define a domain at all
takes it, so there is nothing to check.  Whether the pool's filesystem can serve
the mode being asked for is a different question, and C<pool_fstype> is the one
that answers it.

=cut

sub supports {
    my ( $self, $feature ) = @_;
    my $needs = $DISK_FEATURE{$feature} or die "No such disk feature as '$feature'\n";

    return $self->{supports}{$feature} //= $self->_meets($needs);
}

# In this order on purpose: the qemu-img probe costs a command on the far side,
# and there is no point paying for it to find out that the libvirt in front of
# it would not have passed the option along anyway.
sub _meets {
    my ( $self, $needs ) = @_;

    return 0 if $self->libvirt_version < _version_number( $needs->{libvirt} );
    return 0 if $needs->{qemu}     && $self->qemu_version < _version_number( $needs->{qemu} );
    return 0 if $needs->{qemu_img} && !$self->qemu_img_options->{ $needs->{qemu_img} };
    return 1;
}

# libvirt's own encoding, so the versions quoted from its documentation can be
# compared against what the connection reports without converting either.
sub _version_number {
    my ($version) = @_;

    # A character class rather than an escape: split takes a pattern whatever it
    # is handed, so '.' here would split on every character, and m/\./ is a
    # simple substring match as far as perlcritic is concerned.
    my ( $major, $minor, $release ) = split( m/[.]/, $version );
    return ( $major * 1_000_000 ) + ( $minor * 1_000 ) + ( $release // 0 );
}

=head2 qemu_img_options

The qcow2 creation options this hypervisor's C<qemu-img> understands, as a set.

libvirt makes qcow2 volumes by running C<qemu-img create>, and hands it whatever
the volume XML asked for.  An option this qemu has never heard of is therefore a
volume that fails to create, not a volume that quietly comes back without the
feature -- and the volume XML has been able to carry these for longer than qemu
has implemented them, so the libvirt version does not answer the question on its
own.

An empty set when there is no qemu-img to ask, which reads as "none of them" and
gets the disk made the way it was made before.

=cut

sub qemu_img_options {
    my ($self) = @_;
    return $self->{qemu_img_options} if $self->{qemu_img_options};

    # -o help lists the options for the format and exits; it wants no filename.
    my $help    = $self->capture_cmd('qemu-img create -f qcow2 -o help 2>/dev/null') // '';
    my %options = map { $_ => 1 } ( $help =~ m/^\s+(\w+)=/gmx );

    print "Could not ask qemu-img on " . $self->describe . " which qcow2 options it takes,\n" . "so this disk gets none of the optional ones.\n"
      unless %options;

    return $self->{qemu_img_options} = \%options;
}

=head2 pool_fstype

The filesystem the storage pool sits on, as C<stat -f> names it.

Which matters here for one thing: whether C<cache='none'> can work.  That mode
opens the disk image C<O_DIRECT>, and on a filesystem with no O_DIRECT the open
fails -- so the domain defines cleanly and then refuses to start, which is the
worst place to find out.

=cut

sub pool_fstype {
    my ($self) = @_;
    return $self->{pool_fstype} if defined $self->{pool_fstype};

    # Single-quoted rather than handed to run(): capture() takes a shell string
    # by contract, and a pool path is the one thing here that came from a
    # configuration file rather than from us.
    ( my $quoted = $self->pool_path ) =~ s/'/'\\''/g;

    my $type = $self->capture_cmd("stat -f -c %T '$quoted' 2>/dev/null") // '';
    chomp $type;

    return $self->{pool_fstype} = $type;
}

=head2 pool_takes_direct_io

Whether a file in the storage pool can be opened C<O_DIRECT> and written to,
which is the whole of what C<cache='none'> needs of a filesystem.

Asked of the filesystem rather than worked out from its name, because the name
does not answer it and a list of names that supposedly do was wrong about every
entry on it.  tmpfs takes an O_DIRECT write on a current kernel.  ZFS grew real
Direct I/O in OpenZFS 2.3, where it is then subject to the pool's feature flags
and to the dataset's own C<direct> property -- so not even the version settles
that one, and a table here would be a stale copy of three things that move on
somebody else's schedule.

A 4K direct write into the pool directory is the same open qemu is about to do,
and it answers for all of the above and for whatever the pool is on next.  Not
sudo, for the same reason C<base_image> is not: a pool directory this user
cannot write to is one the base image could never have been downloaded into.

=cut

sub pool_takes_direct_io {
    my ($self) = @_;
    return $self->{pool_takes_direct_io} if defined $self->{pool_takes_direct_io};

    my $probe = $self->pool_path . "/.odirect-probe.$$";

    # dd rather than perl: this is the one machine in the fleet we have not
    # asked to have anything installed on, and coreutils is not a dependency
    # the way an interpreter would be.  It opens with O_DIRECT and writes a
    # block, so a filesystem that refuses either one fails here.
    my $taken = $self->run_cmd(
        'sh', '-c',
        'dd if=/dev/zero of="$1" bs=4096 count=1 oflag=direct >/dev/null 2>&1; status=$?; rm -f "$1"; exit $status',
        'sh', $probe,
    ) == 0;

    return $self->{pool_takes_direct_io} = $taken ? 1 : 0;
}

=head2 zfs_version

The OpenZFS release this hypervisor is running, or undef where there is no ZFS.

Only ever used to say something useful in the message when a pool on ZFS turns
out not to take an O_DIRECT write: Direct I/O arrived in 2.3, so the version is
the difference between "upgrade and this gets faster" and "this pool is
configured not to".

=cut

sub zfs_version {
    my ($self) = @_;
    return $self->{zfs_version} if exists $self->{zfs_version};

    my $version = $self->capture_cmd('cat /sys/module/zfs/version 2>/dev/null') // '';
    chomp $version;

    return $self->{zfs_version} = length $version ? $version : undef;
}

# qemu's default cluster, and the one worth moving to on a disk large enough to
# have outgrown the metadata cache.
my $QCOW2_DEFAULT_CLUSTER = 64 * 1024;
my $QCOW2_LARGE_CLUSTER   = 1024 * 1024;

# What qemu will spend on qcow2 metadata by default, and the most we are willing
# to ask it to spend instead.  Both are per running domain and both are host
# memory, which is memory Trog::Hypervisors is not counting.
my $QCOW2_METADATA_DEFAULT = 32 * 1024 * 1024;
my $QCOW2_METADATA_CAP     = 256 * 1024 * 1024;

# Above this the default metadata cache stops covering the whole image.  See
# qcow2_tuning for where the number comes from.
my $QCOW2_LARGE_DISK = 128 * 1024 * 1024 * 1024;

=head2 qcow2_tuning($capacity)

How a qcow2 of this size should be laid out on this hypervisor: the cluster size
to make it with, whether it gets subcluster allocation, and how much metadata
cache the domain should ask for.  Returns those three as a hash, with anything
we have no opinion about left out.

Two facts decide it, and they pull against each other.

The first is that every guest disk here is an overlay on the shared base image,
and without C<extended_l2> the smallest thing an overlay can allocate is a whole
cluster.  A 4K write into a 64K hole means reading 64K out of the backing file,
merging, and writing 64K back -- for the life of the disk, on every guest,
because every guest is an overlay.  Subclusters cut the allocation unit to a
32nd of a cluster and the read-modify-write goes with it.  So it is on wherever
qemu will take it: it is the single biggest thing available to a layout like
ours, and it costs nothing to have.

The second is that it is not free after all, at size.  An extended L2 entry is
twice the width, so the metadata cache covers half as much image -- qemu's
default 32 MiB reaches 256 GiB of image at the default 64 KiB cluster, and
128 GiB once entries are doubled.  Past that, random I/O starts paying for L2
reads that used to be cached, which is exactly the workload the subclusters were
bought for.

Larger clusters buy the coverage back, sixteenfold at 1 MiB, for a coarser
allocation unit -- 32 KiB subclusters rather than 2 KiB.  That is a trade worth
making only on a disk big enough to need it, so it is made only there, and the
metadata cache is raised on top for the rare disk that outgrows even that.

=cut

sub qcow2_tuning {
    my ( $self, $capacity ) = @_;

    my %tuning = ( extended_l2 => $self->supports('extended_l2') ? 1 : 0 );

    # One L2 entry per cluster, twice as wide when it also carries the
    # subcluster allocation bitmap.
    my $entry = $tuning{extended_l2} ? 16 : 8;

    $tuning{cluster_size} = $QCOW2_LARGE_CLUSTER
      if $capacity > $QCOW2_LARGE_DISK && $self->supports('cluster_size');

    my $cluster = $tuning{cluster_size} // $QCOW2_DEFAULT_CLUSTER;
    my $wanted  = int( $capacity / $cluster ) * $entry;

    return %tuning unless $wanted > $QCOW2_METADATA_DEFAULT && $self->supports('metadata_cache');

    $tuning{metadata_cache} = $wanted < $QCOW2_METADATA_CAP ? $wanted : $QCOW2_METADATA_CAP;
    return %tuning;
}

sub bridge_device {
    my ($self) = @_;
    return $self->{bridge_device} if defined $self->{bridge_device};

    my $device = $self->capture_cmd(q{brctl show | grep -vP 'vnet|virbr' | tail -n1 | awk '{print $1}'});
    chomp $device if defined $device;
    die "Could not determine outbound bridge device on " . $self->uri . "!\n" . "Set bridge_device in provision.conf if autodetection can't find it.\n"
      unless $device;

    return $self->{bridge_device} = $device;
}

sub virbr_device {
    my ($self) = @_;
    return $self->{virbr_device} if defined $self->{virbr_device};

    my $device = $self->capture_cmd(q{brctl show | grep virbr | tail -n1 | awk '{print $1}'});
    chomp $device if defined $device;
    die "Could not determine libvirt network device on " . $self->uri . "!\n" . "Set virbr_device in provision.conf if autodetection can't find it.\n"
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

What the hypervisor has, what its guests have already been promised, and
whether one more will fit.  All of it comes from libvirt, so it is what the
hypervisor actually believes rather than what a config file claimed a year ago.

Memory is counted as I<committed> rather than I<used>: a guest that has been
promised 8G is holding 8G against us even while it idles at 400M.  Overcommit
memory and the OOM killer eventually picks one of your VMs.  CPUs are the other
way round -- overcommitting cores is normal and expected -- so those are
measured against C<cpu_overcommit> times the physical count.

=head2 capacity

A snapshot of the hypervisor, cached for the life of the object:

    memory_mb        physical memory
    memory_committed committed to guests, running or not
    memory_free      what is left after the reserve
    cpus             physical CPUs
    cpus_allocatable cpus * cpu_overcommit
    cpus_committed   vCPUs handed to running guests
    cpus_free        what is left after the reserve
    disk_free        free bytes in the storage pool, after the reserve
    guests           how many domains it knows about

Dies if libvirt cannot be reached, since a hypervisor we cannot ask about is
not one we should be placing guests on.

=cut

sub capacity {
    my ($self) = @_;
    return $self->{capacity} if $self->{capacity};

    my $node    = $self->vmm->get_node_info();
    my @domains = $self->vmm->list_all_domains();

    my ( $memory_committed, $cpus_committed ) = ( 0, 0 );
    foreach my $domain (@domains) {
        my $info = eval { $domain->get_info() } or next;

        # maxMem is what the guest may grow into, and is what we have to hold
        # against the host whether or not it is using it yet.
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

Free bytes in the storage pool, or 0 when there isn't one yet -- a pool
nothing has built yet has no space in it, which is the honest answer.

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

The storage pool's directory, which a hypervisor may not have yet, and
F<virtiofs-better> in F</usr/libexec>.  That one runs as part of the qemu
process, so it has to land on the hypervisor, not on us.

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

Eject the cloud-init ISO, which is only so the guest does not boot off it next
time.  See L</eject_cdrom($domain, $target)> for why this waits on cloud-init.

=head2 guest_volumes($domain)

The guest's own overlay and its seed, those of them there are.

=cut

sub release_seed { return $_[0]->eject_cdrom( $_[1] ) }

sub guest_volumes {
    my ( $self, $domain ) = @_;
    return grep { $self->volume($_) } ( "$domain-qcow2", "$domain-cloudinit.iso" );
}

=head2 guest_ssh_ip($config, $lease_ip)

Which address I<we> use to SSH into a guest.

On a local hypervisor the libvirt NAT lease is reachable and always was.  On a
remote one it isn't -- it only routes from the hypervisor itself -- so we need
the guest's bridged static address instead, and there is no way to guess it.

=cut

sub guest_ssh_ip {
    my ( $self, $config, $lease_ip ) = @_;
    return $lease_ip if $self->is_local;

    my ($ip) = grep { defined $_ && length $_ } $config->param('ips');
    die "Provisioning against a remote hypervisor (" . $self->uri . ") requires the guest to have a\n" . "routable address: set 'ips' in provision.conf.  The libvirt NAT lease (" . ( $lease_ip // 'none' ) . ") is only\nreachable from the hypervisor itself.\n"
      unless $ip;
    return $ip;
}

=head1 SEE ALSO

L<Sys::Virt>

=cut

=head2 @names = $hv->preflight_checks(), $hv->preflight_notes()

What C<bin/preflight> asks of this backend, in order.

=cut

sub preflight_checks { return qw{check_reachable check_passwordless_sudo check_iso_builder check_rsync check_transfer_ip check_fetch_sources check_libvirt check_sys_virt_in_step check_config} }
sub preflight_notes  { return qw{note_libguestfs note_swtpm note_stale_image note_apt_mirror note_log_destination note_pool_quota} }

sub check_reachable {
    my ($self) = @_;

    return $self->_verdict( 1, 'The hypervisor is this machine', q{} ) if $self->is_local;

    my $whoami = eval { $self->capture_cmd('whoami') };
    chomp $whoami if defined $whoami;

    return $self->_verdict( 1, "Reached " . $self->ssh_target . " as $whoami", q{} )
      if defined $whoami && length $whoami;

    return $self->_verdict( 0, 'Cannot reach ' . $self->describe, <<"FIX" );
ssh -v @{[ $self->ssh_target ]} and see what it says.  This wants an agent or a
key already trusted there; nothing here can answer a password prompt.
FIX
}

# A guest fetches its payload from this machine, over ssh, so it has to have an
# address of ours to fetch from.  Which of ours depends on how this machine is
# attached to the hypervisor's networks, and on a workstation that is not on any
# of them there is no answer -- which is the whole run failing at the guest's
# first target rather than here, so it is worth a question up front.
#
# This asks the routing table, which cannot see a firewall in between or a route
# that only works one way.  It says there is an address to try, not that the
# guest will get through on it.
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

Put this machine on that network, or name the address yourself in the [global]
section of ipmap.cfg:

    transfer_ip = 192.0.2.10
FIX
}

# The lease helper is the whole of what a provision still needs root on a
# hypervisor for, bar a one-off install of virtiofs-better and bin/nuke_pool.
# So "no sudo" and "exactly enough sudo" are different answers, and `sudo -n
# true` cannot tell them apart -- it fails for the second as loudly as for the
# first, and the fix it then prints is a standing grant of root that was not
# needed.
my $LEASE_HELPER = '/usr/lib/libvirt/libvirt_leaseshelper';

sub check_passwordless_sudo {
    my ($self) = @_;

    if ( $self->run_cmd(qw{sudo -n true}) == 0 ) {
        my $allowed = eval { $self->capture_cmd('sudo -n -l 2>/dev/null') } // q{};
        my $whole   = $allowed =~ m/NOPASSWD:\s*ALL/;

        return $self->_verdict( 1, 'Passwordless sudo, for everything', q{} ) if $whole;
        return $self->_verdict( 1, 'Passwordless sudo',                 q{} );
    }

    # Narrowed rather than absent: enough for a provision, not enough for
    # bin/nuke_pool, which is the correct shape for a grant handed to something
    # that builds guests unattended.
    return $self->_verdict( 1, "Passwordless sudo for $LEASE_HELPER, which is what a provision needs", <<"FIX" )
bin/nuke_pool will not work for this account, which is deliberate at this
level.  Widen the grant if you need it.
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

That leaves bin/nuke_pool needing root it does not have, and needs
/usr/libexec/virtiofs-better already in place -- bin/provision installs it on
first use, which is the one step that wants the wider grant.
FIX
}

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

# Sys::Virt is released in lockstep with libvirt and binds the API of the
# release it was built against.  Talk to a daemon from a different one and the
# failures are not "version mismatch": they are a constant that is not exported,
# or a call the far side does not implement, surfacing as an error about
# whatever was being attempted at the time.
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

# A hypervisor with a TPM of its own can give its guests emulated ones worth
# having, and swtpm is what emulates them.  Only worth saying where there is
# hardware to make it mean something: on a machine with no TPM, installing swtpm
# would buy a guest a TPM sealed to a file next to its disk image, which is why
# bin/provision does not give it one.  Nothing to fix there, so nothing said.
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

# What the guests built here can actually be held to, which is a question worth
# asking before handing an unattended runner a key.
#
# Nothing in libvirt counts what anybody has allocated, and on the system URI
# every guest runs as libvirt-qemu whoever defined it, so there is no UID for a
# disk quota to attach to.  The pool being on a filesystem with a limit is the
# only thing that makes one real -- and a pool whose capacity is the whole
# filesystem is a pool that can fill the hypervisor root.
#
# A note rather than a check: this is what every hypervisor looks like today,
# and refusing to build anything over it would be wrong.
sub note_pool_quota {
    my ($self) = @_;

    # Asked of libvirt directly rather than through Trog::HV::pool, which
    # defines and starts a pool it cannot find.  A check that builds something
    # is not a check.
    my $name = $self->pool_name;
    my $info = eval { $self->vmm->get_storage_pool_by_name($name)->get_info() } or return { ok => 1 };

    # -B1 without -P, which df refuses alongside --output; the last line is the
    # mount, and its second field is the size in bytes.
    my $path    = $self->pool_path;
    my $said    = eval { $self->capture_cmd("df -B1 '$path' 2>/dev/null | tail -n1") } // q{};
    my ($bytes) = $said =~ m/\A\S+\s+(\d+)\s/;

    # Within a gigabyte of the filesystem it sits on means it is not a limit,
    # it is the filesystem -- the pool is a directory, and libvirt reports what
    # statvfs says about whatever it is mounted on.
    return { ok => 1 }
      unless defined $bytes && abs( $bytes - ( $info->{capacity} // 0 ) ) < 1_073_741_824;

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

# Is anything keeping the logs the fleet produces?
#
# Two things worth saying.  A collector built and nothing shipping to it is the
# more annoying: the sink exists and every guest is still talking to itself.
# Leftover drop-ins on the hypervisor are the upgrade case -- provisioning used
# to write one per guest there, for a listener that on most installations was
# never opened.
#
# Reads the configuration, and asks the hypervisor only what it already has a
# connection for.  It does not ask the ip pool anything: that would have a
# read-only command create ips.db.
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

    # What provisioning used to write, for a listener it never opened.  Only the
    # per-domain ones this tool made: everything else in there is the
    # distribution's or another recipe's.
    my %known = map       { $_ => 1 } @domains;
    my @stale = sort grep { $known{$_} }
      map { m/\A10-(.+)[.]conf\z/ ? $1 : () } eval { $self->list_dir('/etc/rsyslog.d') };

    if (@stale) {

        # Comma-joined with no spaces on purpose: that is a brace expansion the
        # operator can paste, and one with spaces in it is not.
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

# libvirt packs its version into one integer: major * 1000000 + minor * 1000 +
# release.  Named apart from libvirt_version above, which asks the connection
# what it is running rather than spelling out an answer already in hand.
sub _version_string {
    my ($packed) = @_;
    return sprintf '%d.%d.%d', int( $packed / 1000000 ), int( $packed / 1000 ) % 1000, $packed % 1000;
}

1;
