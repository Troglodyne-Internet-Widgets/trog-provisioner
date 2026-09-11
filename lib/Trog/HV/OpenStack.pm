package Trog::HV::OpenStack;

#ABSTRACT: the OpenStack backend: Nova servers, Neutron addresses and Cinder disks.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';
use parent 'Trog::HV';

use List::Util qw{first};
use MIME::Base64();
use OpenStack::MetaAPI();

use Trog::OpenStack::Auth();
use Trog::OpenStack::Config();

=head1 NAME

Trog::HV::OpenStack - the OpenStack backend: Nova servers, Neutron addresses and
Cinder disks

=head1 SYNOPSIS

    # Not built directly.  A hypervisors.conf block naming a cloud gets you one.
    my $hv = Trog::HV->new(cloud => 'openstack', flavor => 'm1.medium');

    $hv->create_guest(name => 'vm.example.test', user_data => $cloud_config);
    print $hv->guest_ssh_ip($config), "\n";
    $hv->annihilate_domain('vm.example.test');

=head1 DESCRIPTION

A cloud we build guests on by asking Nova, rather than a machine we build them
on by asking libvirt.

The words change with the thing underneath them, and the differences are not
cosmetic:

=over 4

=item * A guest has a B<flavor>, not a disk size and a memory figure.  What
sizes exist is the cloud's to say, and F<hypervisors.conf> names one.

=item * There is no B<storage pool>, and no path on a filesystem where a disk
image sits.  A root disk comes from a Glance image, and anything else is a
Cinder volume.

=item * There is no B<cdrom>, so no C<cidata> ISO.  Nova takes the cloud-init
payload as C<user_data> and hands it to the guest itself.

=item * There is no B<NAT lease> to look up.  Neutron assigns the address, and
a floating IP is what makes it reachable from outside.

=item * Most importantly, B<there is no hypervisor to get a shell on.>  There is
an API endpoint.

=back

That last one is why C<is_local> is true here: there is no hypervisor filesystem
to reach, so every file operation L<Trog::Machine> offers is a local one.

=head2 The payload needs nothing special

A guest fetches C<data.tar.gz> from L<Trog::Local> -- the machine running this
tool -- rather than from its hypervisor, so there is no hypervisor in that
arrangement to be missing.  A cloud guest fetches exactly as a libvirt one does,
from the same place, with the key F<bin/provision> put in the same
C<authorized_keys>.

What it does need is to be able to reach us, and that is a question about
routing rather than about backends: L<Trog::Local/transfer_ips> works out which
of our addresses it can, and F<bin/preflight> is where that is checked.

=head1 CLASS METHODS

=cut

# Where a cloud keeps the numbers this backend needs.
#
# Nova reports the allowance and the usage together, so both halves of
# "will another guest fit" come from one request.  Cinder reports disk the same
# way, and separately, because block storage has its own quota.
my $GB = 1024 * 1024 * 1024;

# Stamped into every guest's Nova metadata, so a teardown can tell one of ours
# from one somebody else built in the same project.
our $MANAGED_BY = 'trog-provisioner';

# How long to wait for a deleted server to actually go.
our $DELETE_TIMEOUT = 300;

# How long to wait for a rebuilt one to come back.
our $REBUILD_TIMEOUT = 600;

# The first compute microversion whose rebuild takes user_data.  Below it the
# request cannot carry one, and a rebuild without one keeps the payload the
# server was created with.
our $REBUILD_MICROVERSION = '2.57';

=head2 config_keys

The F<hypervisors.conf> keys this backend reads.  C<cloud> is what marks a
block as one of ours: it names an entry in F<clouds.yaml>.

=cut

sub config_keys {
    return ( map { $_ => $_ } qw{cloud flavor image network floating_network availability_zone security_group keypair domain_dir} );
}

=head2 build(%opts)

Build one.  C<cloud> is required, because without it there is no way to know
which cloud out of F<clouds.yaml> is meant, and guessing would be picking one of
somebody's clouds at random.

Nothing is contacted here.  Authentication happens when something first asks a
question that needs answering, so that building the object -- which
C<bin/new_config> does merely to read a path off it -- does not require a
working credential.

=cut

sub build {
    my ( $class, %given ) = @_;

    die "An OpenStack hypervisor needs a 'cloud' naming an entry in clouds.yaml\n"
      unless defined $given{cloud} && length $given{cloud};

    return bless {%given}, $class;
}

=head1 IDENTITY

=head2 is_local

True, and not because the cloud is this machine.

There is no hypervisor filesystem to reach, so the per-domain directory is on
the machine running this, and the file operations that would have gone over SSH
to a hypervisor are local ones.  See L</DESCRIPTION>.

=head2 describe

The cloud, for a diagnostic to name.

=head2 cloud

Which entry in F<clouds.yaml> this is.

=cut

sub is_local { return 1 }

=head2 builds_by_api

True.  A guest is created by asking Nova, so none of the libvirt XML this
toolkit can generate is of any use here.

=head2 manages_addresses

True.  Neutron allocates, and F<ipmap.cfg>'s pool has no part in it.

=cut

sub builds_by_api     { return 1 }
sub manages_addresses { return 1 }
sub cloud             { return $_[0]->{cloud} }
sub describe          { return 'the OpenStack cloud ' . $_[0]->{cloud} }

=head2 uri

The Keystone endpoint, so that anything printing "where are we building this"
has something true to print.

=cut

sub uri {
    my ($self) = @_;
    return $self->{_uri} //= Trog::OpenStack::Config->load( $self->{cloud} )->{auth_url};
}

=head2 flavor, image, network, floating_network, availability_zone, security_group, keypair

What F<hypervisors.conf> said to build guests with.  C<security_group> defaults
to C<default>, which is the group every project has; the rest have no default,
because there is no sensible guess at which image or flavor somebody meant.

=cut

sub flavor            { return $_[0]->{flavor} }
sub image             { return $_[0]->{image} }
sub network           { return $_[0]->{network} }
sub floating_network  { return $_[0]->{floating_network} }
sub availability_zone { return $_[0]->{availability_zone} }
sub keypair           { return $_[0]->{keypair} }
sub security_group    { return $_[0]->{security_group} // 'default' }

=head1 THE API

=head2 api

The L<OpenStack::MetaAPI> this talks to, authenticated and kept.

Built on first use rather than in the constructor, so that an object nobody asks
a cloud question of never needs a credential.

=cut

sub api {
    my ($self) = @_;
    return $self->{_api} if $self->{_api};

    my $auth = Trog::OpenStack::Auth->from_cloud( $self->{cloud} );

    # MetaAPI builds its own auth from constructor arguments unless it is handed
    # one, and the one it builds cannot do application credentials.
    return $self->{_api} = OpenStack::MetaAPI->new( { auth => $auth } );
}

=head1 CAPACITY

What the project is allowed and what it has already used, which is what a quota
is.  L<Trog::HV> does the arithmetic; this only has to answer in the shape it
reads.

=head2 cpu_overcommit

1, always.

A libvirt host is asked for its physical CPU count, and how many vCPUs per core
is acceptable is our judgement to make.  A quota is not a physical count -- it
is already the number of cores this project may run -- so there is nothing left
to overcommit, and multiplying it by four would invent headroom the cloud will
refuse to honour.

=cut

sub cpu_overcommit { return 1 }

=head2 max_guests

The instance quota, unless F<hypervisors.conf> set something lower.

Unlike a libvirt host, a cloud has an opinion about this, and it is the one that
will be enforced whatever we think.

=cut

sub max_guests {
    my ($self) = @_;
    return $self->{max_guests} if $self->{max_guests};
    return $self->capacity->{guests_allowed};
}

=head2 capacity

As L<Trog::HV/capacity>, out of Nova's and Cinder's limits.

C<memory_mb> and C<cpus> are the allowance rather than a physical count, which
is the honest reading: what the project may have is the only number that
constrains anything.  Cached for the life of the object, as libvirt's is.

=cut

sub capacity {
    my ($self) = @_;
    return $self->{capacity} if $self->{capacity};

    my $nova = $self->api->limits->{absolute}        // {};
    my $disk = $self->api->volume_limits->{absolute} // {};

    my $memory_mb   = $nova->{maxTotalRAMSize} // 0;
    my $memory_used = $nova->{totalRAMUsed}    // 0;
    my $cpus        = $nova->{maxTotalCores}   // 0;
    my $cpus_used   = $nova->{totalCoresUsed}  // 0;

    my $disk_total = ( $disk->{maxTotalVolumeGigabytes} // 0 ) * $GB;
    my $disk_used  = ( $disk->{totalGigabytesUsed}      // 0 ) * $GB;

    return $self->{capacity} = {
        memory_mb        => $memory_mb,
        memory_committed => $memory_used,
        memory_free      => $memory_mb - $memory_used - $self->reserve_memory,
        cpus             => $cpus,
        cpus_allocatable => $cpus,
        cpus_committed   => $cpus_used,
        cpus_free        => $cpus - $cpus_used - $self->reserve_cpus,
        disk_free        => $disk_total - $disk_used - $self->reserve_disk,
        guests           => $nova->{totalInstancesUsed} // 0,

        # Not part of the shape Trog::HV reads; max_guests wants it.
        guests_allowed => $nova->{maxTotalInstances} // 0,
    };
}

=head1 GUESTS

A guest is a Nova server whose name is the domain name, which is the same
identity libvirt uses for a domain.

=head2 server($name)

The server called C<$name>, or nothing.

Dies if the cloud has more than one, rather than picking one: two servers
answering to a domain name is a situation to be told about, not to guess at.

=cut

sub server {
    my ( $self, $name ) = @_;

    die "server() needs a name\n" unless defined $name && length $name;

    # The route filters client side on an exact match, so this cannot pick up a
    # guest that merely has $name as a prefix -- which the Nova API's own name
    # filter, being a regex match, would.
    my @found = grep { ref $_ } $self->api->servers( name => $name );

    die "The cloud has " . scalar(@found) . " servers called '$name'; refusing to guess which\n"
      if @found > 1;

    return $found[0];
}

=head2 server_detail($name)

The same guest, in full.

Nova's server I<list> returns only C<id>, C<name> and C<links> -- no status, no
addresses, no metadata.  Anything that needs to know what a guest is actually
doing has to ask for it by id, so this is the call that costs a second request,
and the one those callers use.

=cut

sub server_detail {
    my ( $self, $name ) = @_;

    my $summary = $self->server($name);
    return unless $summary;

    return $self->api->server_from_uid( $summary->{id} );
}

=head2 domain_exists($name)

=head2 domain_is_running($name)

Whether there is such a guest, and whether it is up.  C<ACTIVE> is the only
status that counts as running: a server that is C<BUILD>, C<ERROR> or
C<SHUTOFF> exists without being usable.

=cut

=head2 guest_names

Every server in the project, whatever built it.

Not only the ones this tool made: an orphan sweep is asking "is anything still
using this name", and a server somebody else created is still using it.

=cut

sub guest_names {
    my ($self) = @_;
    return map { $_->{name} } grep { ref $_ } $self->api->servers();
}

sub domain_exists { return defined $_[0]->server( $_[1] ) ? 1 : 0 }

sub domain_is_running {
    my ( $self, $name ) = @_;

    my $server = $self->server_detail($name);
    return 0 unless $server;
    return ( $server->{status} // '' ) eq 'ACTIVE' ? 1 : 0;
}

=head2 guest_ssh_ip($config)

The address to reach a guest at: its floating IP.

A fixed address on a tenant network only routes from inside that network, so
unlike libvirt's NAT lease -- which at least works from the hypervisor -- it is
no use to us at all.  Dies naming the guest when it has no floating IP, because
the alternative is handing back an address that will silently never connect.

=cut

sub guest_ssh_ip {
    my ( $self, $config, $name ) = @_;

    $name //= ref $config ? $config->param('domain') : $config;

    my $server = $self->server_detail($name)
      or die "There is no guest called '$name' on " . $self->describe . "\n";

    my @addresses = grep { _is_ipv4($_) } $self->_addresses($server);

    # A floating IP is the usual way out of a tenant network, so where there is
    # one it wins.
    my $floating = first { ( $_->{'OS-EXT-IPS:type'} // '' ) eq 'floating' } @addresses;
    return $floating->{addr} if $floating;

    # But not every cloud has a tenant network to escape from.  Where the only
    # network is external and shared, a guest on it is reachable at the address
    # it was given, and Nova calls that address 'fixed' -- so insisting on a
    # floating one would reject a guest that is answering perfectly well.
    my $reachable = first { $self->_network_is_external( $_->{network} ) } @addresses;
    return $reachable->{addr} if $reachable;

    die "The guest '$name' has no address we can reach it at.\n" . "It is on " . ( join( ', ', map { "$_->{network} ($_->{addr})" } @addresses ) || 'no network' ) . ", none of which is external.\n" . "Set floating_network in hypervisors.conf so a routable address gets attached.\n";
}

# Nova reports addresses as a hash of network name => list of addresses, which
# is one level of nesting more than any caller here cares about.
sub _addresses {
    my ( $self, $server ) = @_;

    my $addresses = $server->{addresses};
    return () unless ref $addresses eq 'HASH';

    return map {
        my $network = $_;
        map {
            { %$_, network => $network }
        } @{ $addresses->{$network} }
    } sort keys %$addresses;
}

# ssh would take either, but the rest of this toolkit deals in IPv4 -- 'ips' in
# provision.conf is a list of them -- so handing back a v6 address would be
# handing it somewhere that cannot hold it.
sub _is_ipv4 { return ( $_[0]->{addr} // '' ) =~ m/\A[0-9]+(?:[.][0-9]+){3}\z/ ? 1 : 0 }

# Is this network one the outside world can route to?
#
# Cached, because guest_ssh_ip is asked repeatedly while waiting for a guest to
# come up, and the answer cannot change underneath us in that time.
sub _network_is_external {
    my ( $self, $name ) = @_;

    return 0 unless defined $name && length $name;
    return $self->{_external}{$name} if exists $self->{_external}{$name};

    my ($network) = grep { ref $_ && ( $_->{name} // '' ) eq $name } $self->api->networks();

    return $self->{_external}{$name} = ( $network && $network->{'router:external'} ) ? 1 : 0;
}

=head1 SNAPSHOTS

Nova snapshots a server into a Glance image.  Glance images are per project
rather than per server, so the guest a snapshot belongs to has to be in its
name; C<$domain@$snapshot> is that, and C<@> is a character no domain name and
no libvirt snapshot name contains.

=head2 snapshot_names($domain)

The snapshots taken of this guest, newest first.

=cut

sub snapshot_names {
    my ( $self, $domain ) = @_;

    # Filtered at Glance rather than here: Nova stamps every snapshot it takes
    # with image_type, so this asks for snapshots and not for the base images
    # the project also holds.  Narrowing to one guest is the name prefix, and
    # that Glance cannot do -- it matches a name exactly or not at all.
    my @images =
      sort { ( $b->{created_at} // '' ) cmp ( $a->{created_at} // '' ) }
      grep { ref $_ && index( $_->{name} // '', "$domain\@" ) == 0 } $self->api->list_images( image_type => 'snapshot' );

    return map { substr $_->{name}, length("$domain\@") } @images;
}

=head2 snapshot_current_name($domain)

The most recent snapshot of this guest.

libvirt tracks which snapshot a domain is "on"; Glance has no such pointer, so
this is the newest one by creation time, which is what the caller is after.

=cut

sub snapshot_current_name {
    my ( $self, $domain ) = @_;

    my ($newest) = $self->snapshot_names($domain);
    return $newest;
}

=head2 create_snapshot($domain, $name)

=head2 revert_snapshot($domain, $name)

Take one, and put the guest back on one.  Reverting is a Nova rebuild onto the
snapshot's image, which keeps the server -- and so its addresses and its
floating IP -- and replaces what is on its root disk.

=cut

sub create_snapshot {
    my ( $self, $domain, $name ) = @_;

    my $server = $self->server($domain)
      or die "There is no guest called '$domain' to snapshot\n";

    $self->api->create_image( $server->{id}, name => "$domain\@$name" );
    return 1;
}

sub revert_snapshot {
    my ( $self, $domain, $name ) = @_;

    my $server = $self->server($domain)
      or die "There is no guest called '$domain' to revert\n";

    # By exact name, which Glance answers without enumerating anything.
    my $image = $self->api->image_from_name("$domain\@$name");
    $image = $image->[0] if ref $image eq 'ARRAY';

    die "The guest '$domain' has no snapshot called '$name'\n"
      unless ref $image eq 'HASH' && $image->{id};

    $self->api->server_action( $server->{id}, { rebuild => { imageRef => $image->{id} } } );
    return 1;
}

=head1 BUILDING AND TEARING DOWN

=head2 create_guest(%spec)

Build a guest, and wait for Nova to call it C<ACTIVE> and give it a floating IP.

C<name> is required.  C<flavor>, C<image>, C<network>, C<floating_network>,
C<availability_zone>, C<security_group> and C<keypair> each default to what
F<hypervisors.conf> said, so a caller normally passes only the name and the
payload.

C<user_data> is the cloud-init payload.  It goes to Nova as a field on the
server, which is the whole of what replaces the C<cidata> ISO.

Everything built this way is tagged in its Nova metadata as ours, so that a
later teardown can tell a guest this tool made from one somebody else did.

Returns the server, including C<floating_ip_address>.

=cut

sub create_guest {
    my ( $self, %spec ) = @_;

    my $name = $spec{name};
    die "create_guest needs a name\n" unless defined $name && length $name;

    # Say which one is missing and where it goes.  There is no guessing a flavor
    # or an image: what exists is the cloud's to say.
    #
    # floating_network is not among them.  A cloud whose only network is
    # external needs no floating IP, and demanding one here would make such a
    # cloud unbuildable; guest_ssh_ip is where not having a reachable address
    # actually becomes a problem, and it says so there.
    foreach my $needed (qw{flavor image network}) {
        $spec{$needed} //= $self->{$needed};
        die "Building '$name' on " . $self->describe . " needs '$needed'.\n" . "Set it in the cloud's block in hypervisors.conf, or pass it here.\n"
          unless defined $spec{$needed} && length $spec{$needed};
    }

    $spec{floating_network} //= $self->floating_network;

    my @optional;
    push @optional, ( key_name => $spec{keypair} // $self->keypair )
      if defined( $spec{keypair} // $self->keypair );
    push @optional, ( availability_zone => $spec{availability_zone} // $self->availability_zone )
      if defined( $spec{availability_zone} // $self->availability_zone );
    push @optional, ( user_data => $spec{user_data} )
      if defined $spec{user_data} && length $spec{user_data};
    push @optional, ( network_for_floating_ip => $spec{floating_network} )
      if defined $spec{floating_network} && length $spec{floating_network};

    return $self->api->create_vm(
        name           => $name,
        flavor         => $spec{flavor},
        image          => $spec{image},
        network        => $spec{network},
        security_group => $spec{security_group} // $self->security_group,
        metadata       => { %{ $spec{metadata} // {} }, managed_by => $MANAGED_BY, domain => $name },
        @optional,
    );
}

=head2 rebuild_guest($name, user_data => $seed)

Put a fresh root disk from the image under a guest that already exists, with a
new cloud-init payload, and wait for Nova to call it C<ACTIVE> again.

A rebuild keeps the server, and so its ports, its floating IP and any volume
attached to it.  What it replaces is the root disk, which is also what
rebuilding a libvirt guest replaces: its overlay is made again from the base
image.  C<image> defaults to what F<hypervisors.conf> said, like
L</create_guest(%spec)>.

The payload is the point.  It holds the key F<bin/provision> just let in, and a
rebuild that kept the old one would bring the guest up locked against us -- so
this asks Nova for the microversion that takes it, and a cloud too old to give
that refuses the request rather than quietly rebuilding from the stale one.

Returns the server, in full.

=cut

sub rebuild_guest {
    my ( $self, $name, %spec ) = @_;

    my $server = $self->server($name)
      or die "There is no guest called '$name' to rebuild\n";

    my $image = $spec{image} // $self->image;
    die "Rebuilding '$name' on " . $self->describe . " needs 'image'.\n" . "Set it in the cloud's block in hypervisors.conf, or pass it here.\n"
      unless defined $image && length $image;

    my %rebuild = ( imageRef => $self->_image_id($image) );
    $rebuild{user_data} = MIME::Base64::encode_base64( $spec{user_data}, '' )
      if defined $spec{user_data} && length $spec{user_data};

    $self->_nova( POST => "/servers/$server->{id}/action", { rebuild => \%rebuild }, $REBUILD_MICROVERSION );

    return $self->_wait_for_active( $server->{id}, $name );
}

# Nova's rebuild wants an image id, and hypervisors.conf may well name one.
sub _image_id {
    my ( $self, $image ) = @_;

    return $image if $image =~ m/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;

    my $found = $self->api->image_from_name($image);
    $found = $found->[0] if ref $found eq 'ARRAY';

    die "There is no image called '$image' on " . $self->describe . "\n"
      unless ref $found eq 'HASH' && $found->{id};

    return $found->{id};
}

# Nova, at a microversion.  MetaAPI's own post sends no version header, so Nova
# answers it as 2.1 -- whose rebuild has no user_data to send.
sub _nova {
    my ( $self, $method, $path, $body, $microversion ) = @_;

    my $compute = $self->api->route->service('compute');
    my %headers = defined $microversion ? ( 'OpenStack-API-Version' => "compute $microversion" ) : ();

    return $compute->client->call( $method, \%headers, $compute->root_uri($path), $body );
}

# Poll until Nova has finished with the server.  ACTIVE with a task still
# running is a rebuild that has not started yet rather than one that has
# finished, and ERROR will not change on its own, so it is said at once along
# with whatever Nova said caused it.
sub _wait_for_active {
    my ( $self, $uid, $name, $timeout ) = @_;

    $timeout //= $REBUILD_TIMEOUT;
    my $deadline = time + $timeout;

    while (1) {
        my $detail = $self->api->server_from_uid($uid) // {};
        my $status = uc( $detail->{status} // '' );

        return $detail if $status eq 'ACTIVE' && !$detail->{'OS-EXT-STS:task_state'};

        die "Rebuilding '$name' left it in ERROR: " . ( $detail->{fault}{message} // 'Nova did not say why' ) . "\n"
          if $status eq 'ERROR';

        last if time >= $deadline;
        sleep 2;
    }

    die "The guest '$name' was not ACTIVE ${timeout}s after being rebuilt.\n" . "Check its status, and its console log for what it is doing.\n";
}

=head2 prepare_host

=head2 release_seed($domain)

=head2 guest_volumes($domain)

Nothing, each for its own reason.  There is no machine to prepare: Nova builds
the guest, and its disk comes from Glance rather than from a pool.  There is no
seed to release: C<user_data> is a field on the server, not a drive in it.  And
there are no volumes left to delete once a guest is gone, because the ones this
tool made went with the server -- see L</annihilate_domain($name)>, which is where the
decision about which of them were ours is made.

=cut

sub prepare_host  { return 1 }
sub release_seed  { return 1 }
sub guest_volumes { return () }

=head2 annihilate_domain($name)

Take the guest away, and everything it was costing money for.

Deleting the server releases its floating IP -- an address left allocated to
nothing is billed exactly the same as one in use, and is the classic way a cloud
bill grows without anybody deciding it should.

Volumes are deleted only when this tool named them, which it does as
C<$domain-$purpose>.  A volume somebody else attached to the guest by hand is
left alone: guessing wrong here destroys data, so the rule is narrow on purpose
and the leftovers are named rather than removed.

Returns false when there was no such guest, which makes it safe to call on a
name that may already be gone.

=cut

sub annihilate_domain {
    my ( $self, $name ) = @_;

    my $server = $self->server($name);
    return 0 unless $server;

    my @ours = grep { index( $_->{name} // '', "$name-" ) == 0 } $self->_volumes;

    $self->api->delete_server( $server->{id} );

    # A volume attached to a server Nova has not finished deleting is still in
    # use, and Cinder refuses to delete it.  So wait for the server to go before
    # asking, rather than asking and reporting a failure that only meant "not
    # yet".
    $self->_wait_for_gone($name);

    foreach my $volume (@ours) {
        my $ok = eval { $self->api->delete_volume( $volume->{id} ); 1 };
        warn "Could not delete the volume $volume->{name} ($volume->{id}): $@" unless $ok;
    }

    return 1;
}

# Poll until the server is no longer there.  Nova's delete is asynchronous, and
# the interesting failure -- it went to ERROR and stayed -- looks exactly like
# slowness until the wait runs out, so this says which it was.
sub _wait_for_gone {
    my ( $self, $name, $timeout ) = @_;

    $timeout //= $DELETE_TIMEOUT;
    my $deadline = time + $timeout;

    while ( time < $deadline ) {
        return 1 unless $self->server($name);
        sleep 2;
    }

    die "The guest '$name' was still there ${timeout}s after being deleted.\n" . "Check its status: a server that has gone to ERROR will not delete on asking again.\n";
}

=head2 create_volume($domain, $purpose, size_gb => $n)

A Cinder volume for a guest, named so that teardown can recognise it.

=head2 attach_volume($domain, $volume_id)

Attach one to the guest.  Attaching is Nova's end of the job, not Cinder's.

=cut

sub create_volume {
    my ( $self, $domain, $purpose, %opts ) = @_;

    my $size = $opts{size_gb};
    die "create_volume needs a size_gb\n" unless $size;

    return $self->api->create_volume(
        size        => $size,
        name        => "$domain-$purpose",
        description => "$purpose for $domain, made by trog-provisioner",
        %{ $opts{extra} // {} },
    );
}

sub attach_volume {
    my ( $self, $domain, $volume_id ) = @_;

    my $server = $self->server($domain)
      or die "There is no guest called '$domain' to attach a volume to\n";

    return $self->api->attach_volume( $server->{id}, $volume_id );
}

# Cinder's list, flattened -- the route hands back a single hash when there is
# one volume and a list when there are more.
sub _volumes {
    my ($self) = @_;
    return grep { ref $_ } $self->api->volumes();
}

=head2 console_log($domain, $length)

What the guest wrote to its serial console.

When a guest never comes up there is nothing to ssh into and ask, so this is
usually the only thing that will say why.

=cut

sub console_log {
    my ( $self, $domain, $length ) = @_;

    my $server = $self->server($domain)
      or die "There is no guest called '$domain' to read a console log from\n";

    return $self->api->console_output( $server->{id}, $length );
}

=head1 WHAT THIS CANNOT DO

libvirt nouns, which a cloud has no equivalent of.  Each dies naming itself,
rather than returning an undef that would be carried somewhere else before
failing -- a backend that quietly answers the wrong question is worse than one
that refuses.

=over 4

=item * C<define_domain>, C<cloudinit_iso>, C<eject_cdrom>: a Nova server is not
built from libvirt XML and takes its cloud-init as C<user_data>, so there is no
XML to define and no ISO to attach.  See L</create_guest(%spec)>.

=item * C<pool_path>, C<pool_target>, C<nuke_pool>, C<base_image>,
C<create_disk>: there is no storage pool and no path on a filesystem for a disk
to live at.

=item * C<lease_ip>, C<release_dhcp_lease>, C<guest_mac>, C<nic_slots>,
C<nic_names>: Neutron assigns addresses and MACs, there is no NAT lease table to
read and no PCI slot to pin one to -- and an interface name derived from a slot
names a card this guest does not have.

=item * C<has_tpm>: a property of a flavor or an image here, not something to
detect on a host.

=back

=cut

# Named, so that the message says which call was made and what to do instead,
# rather than "method not found on some object".
sub _no_such_thing {
    my ( $self, $method, $because ) = @_;

    die ref($self) . " has no $method: $because\n";
}

sub define_domain { return $_[0]->_no_such_thing( 'define_domain', 'a Nova server is not defined from libvirt XML -- use create_guest' ) }
sub cloudinit_iso { return $_[0]->_no_such_thing( 'cloudinit_iso', 'Nova takes cloud-init as user_data, so there is no ISO to build' ) }
sub eject_cdrom   { return $_[0]->_no_such_thing( 'eject_cdrom',   'there is no cdrom' ) }
sub pool_path     { return $_[0]->_no_such_thing( 'pool_path',     'there is no storage pool' ) }
sub pool_target   { return $_[0]->_no_such_thing( 'pool_target',   'there is no storage pool' ) }
sub nuke_pool     { return $_[0]->_no_such_thing( 'nuke_pool',     'there is no storage pool' ) }
sub base_image    { return $_[0]->_no_such_thing( 'base_image',    'a root disk comes from a Glance image, not a downloaded file' ) }
sub create_disk   { return $_[0]->_no_such_thing( 'create_disk',   'a disk is a Cinder volume -- use create_volume' ) }
sub lease_ip      { return $_[0]->_no_such_thing( 'lease_ip',      'Neutron assigns addresses; there is no lease table' ) }

sub release_dhcp_lease { return $_[0]->_no_such_thing( 'release_dhcp_lease', 'Neutron assigns addresses; there is no lease to release' ) }
sub guest_mac          { return $_[0]->_no_such_thing( 'guest_mac',          'Neutron assigns the MAC, so it cannot be derived from the name' ) }
sub nic_slots          { return $_[0]->_no_such_thing( 'nic_slots',          'there is no PCI topology to pin an interface to' ) }
sub nic_names          { return $_[0]->_no_such_thing( 'nic_names',          'interface names come from Neutron and cloud-init, not from a PCI slot' ) }
sub has_tpm            { return $_[0]->_no_such_thing( 'has_tpm',            'a TPM is a property of the flavor or image, not of a host' ) }

=head1 SEE ALSO

L<Trog::HV>, which chose this backend and does the placement arithmetic.

L<Trog::OpenStack::Auth>, which authenticates it.

L<Trog::HV::Libvirt>, the other one.

=cut

1;
