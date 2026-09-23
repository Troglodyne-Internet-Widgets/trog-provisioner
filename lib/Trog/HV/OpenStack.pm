package Trog::HV::OpenStack;

#ABSTRACT: the OpenStack backend: Nova servers, Neutron addresses and Cinder disks.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::HV::Cloud';

use List::Util qw{first};
use MIME::Base64();
use OpenStack::MetaAPI();

use Provisioner::Cookbook();

use Trog::OpenStack::Auth();
use Trog::OpenStack::Config();

=head1 NAME

Trog::HV::OpenStack - the OpenStack backend: Nova servers, Neutron addresses and
Cinder disks

=head1 SYNOPSIS

    # You do not build one directly.  A hypervisors.conf block that names a cloud makes one.
    my $hv = Trog::HV->new(cloud => 'openstack');

    $hv->create_guest(name => 'vm.example.test', user_data => $cloud_config);
    print $hv->guest_ssh_ip($config), "\n";
    $hv->annihilate_domain('vm.example.test');

=head1 DESCRIPTION

This backend builds guests on a cloud, through the Nova API.  The libvirt
backend builds them on a machine, through libvirt.

The terms change with the platform, and each difference changes what the
backend can do:

=over 4

=item * A guest has a B<flavor>, not a disk size and a memory size.  The cloud
sets which flavors exist, and a guest names the one it is in its C<_global>, as
C<openstack_flavor>.

=item * There is no B<storage pool>, and no disk image file on a filesystem.  A
root disk comes from a Glance image.  Every other disk is a Cinder volume.

=item * There is no B<cdrom>, so there is no C<cidata> ISO.  Nova takes the
cloud-init payload as C<user_data> and gives it to the guest.

=item * There is no B<NAT lease> to look up.  Neutron assigns the address, and a
floating IP makes the guest reachable from outside.

=item * Most important, B<there is no hypervisor to get a shell on.>  There is
only an API endpoint.

=back

The last point is why C<is_local> is true here.  There is no hypervisor
filesystem, so every file operation that L<Trog::Machine> offers runs locally.

=head2 The payload needs nothing special

A guest fetches C<data.tar.gz> from L<Trog::Local>, the machine that runs this
tool, and not from its hypervisor.  So a cloud guest fetches the same way that a
libvirt guest does.  It uses the same source, and the key that F<bin/provision>
put in the same C<authorized_keys>.

The guest must be able to reach this machine.  That is a routing question, not
a backend question.  L<Trog::Local/transfer_ips> finds which of our addresses
the guest can reach, and F<bin/preflight> checks it.

=head1 CLASS METHODS

=cut

# Cinder reports its quota in gigabytes.
my $GB = 1024 * 1024 * 1024;

# Written into the Nova metadata of every guest this tool builds, to mark the
# guest as ours.
our $MANAGED_BY = 'trog-provisioner';

# Seconds to wait for a deleted server to go.
our $DELETE_TIMEOUT = 300;

# Seconds to wait for a rebuilt server to become ACTIVE.
our $REBUILD_TIMEOUT = 600;

# The first compute microversion whose rebuild takes user_data.  Without it, a
# rebuild keeps the payload that the server was created with.
our $REBUILD_MICROVERSION = '2.57';

# The first compute microversion with the remote-consoles call, which took the
# place of os-getVNCConsole.
our $CONSOLE_MICROVERSION = '2.6';

# How many lines of the console Nova is asked for.  It keeps the last 64KB of
# it, so a larger number costs nothing and a smaller one loses the boot.
our $CONSOLE_LINES = 5000;

=head2 @actions = $hv->debug_actions()

C<console>, C<fetch> and C<vnc>.  Nova keeps the console of a server and hands
out a console URL, so those three have an answer here.

The rest of F<bin/debug_boot> edits a libvirt domain or drives libguestfs on
the hypervisor, and a cloud gives us neither the definition nor the disk.
Rescuing a server is the nearest thing to C<--single>, and it boots the server
from a rescue image rather than its own kernel, so it is not that action under
another name.

=cut

sub debug_actions { return qw{console fetch vnc} }

=head2 $restarted = $hv->console_capture($name, wait =E<gt> $seconds)

Returns 0 and does nothing else.  Nova keeps the console of every server, so
there is nothing to redirect and no reason to restart the server.

=cut

sub console_capture { return 0 }

=head2 $text = $hv->console_output($name)

The console log of the server, from C<os-getConsoleOutput>, or undef if Nova
returns none.  The cloud keeps the last part of it, so an old boot is gone.

Dies if the cloud has no server of that name.

=cut

sub console_output {
    my ( $self, $name ) = @_;

    my $server = $self->server($name)
      or die "There is no guest called '$name' on " . $self->describe . "\n";

    my $answer = $self->_nova( POST => "/servers/$server->{id}/action", { 'os-getConsoleOutput' => { length => $CONSOLE_LINES } } );

    return ( ref $answer eq 'HASH' ? $answer->{output} : undef ) || undef;
}

=head2 ($advice, $url) = $hv->vnc_access($name)

The URL of a C<noVNC> session for the server, from the C<remote-consoles> call,
and what the operator has to know about it.

The URL carries a token of its own and the cloud expires it, so it is fetched
each time and not kept.

Dies if the cloud has no server of that name, or if it returns no URL.

=cut

sub vnc_access {
    my ( $self, $name ) = @_;

    my $server = $self->server($name)
      or die "There is no guest called '$name' on " . $self->describe . "\n";

    my $answer = $self->_nova(
        POST => "/servers/$server->{id}/remote-consoles",
        { remote_console => { protocol => 'vnc', type => 'novnc' } },
        $CONSOLE_MICROVERSION
    );

    my $url = ref $answer eq 'HASH' ? $answer->{remote_console}{url} : undef;
    die "$name has no display to connect to on " . $self->describe . "\n" unless $url;

    my $advice = <<"CONSOLE";
$name has a noVNC console.  Open this in a browser:

  $url

The cloud expires the token in it, so ask again rather than keeping it.

CONSOLE

    return ( $advice, $url );
}

=head2 config_keys

Returns the F<hypervisors.conf> keys that this backend reads.  C<cloud> marks a
block as one for this backend.  It names an entry in F<clouds.yaml>.

=head2 marker

Returns C<cloud>.  See L<Trog::HV/backend_for(%opts)>.

=cut

sub marker   { return 'cloud' }
sub size_key { return 'openstack_flavor' }

sub config_keys {
    return ( map { $_ => $_ } qw{cloud network floating_network availability_zone security_group keypair domain_dir} );
}

=head2 build(%opts)

Returns a new backend object.  C<cloud> is required, because without it there
is no way to know which cloud in F<clouds.yaml> to use.

Dies when C<cloud> is not given.

This does not contact the cloud.  Authentication happens at the first call that
needs the API.  So C<bin/new_config> can build the object to read a path off it,
without a working credential.

=cut

sub build {
    my ( $class, %given ) = @_;

    die "An OpenStack hypervisor needs a 'cloud' naming an entry in clouds.yaml\n"
      unless $given{cloud};

    return bless {%given}, $class;
}

=head1 IDENTITY

L<Trog::HV::Cloud> answers C<is_local>, C<builds_by_api> and
C<manages_addresses> for every backend that builds by API.

=head2 cloud

Returns the name of the entry in F<clouds.yaml> that this object uses.

=head2 describe

Returns a name for the cloud, for a diagnostic message.

=cut

sub cloud ($self) { return $self->setting('cloud') }

# The block's value rather than setting's, so that a message never prints what
# a secret: reference resolved to.
sub describe ($self) { return 'the OpenStack cloud ' . $self->{cloud} }

=head2 uri

Returns the Keystone endpoint, so that a message about where a guest is built
has a correct value to show.

=cut

sub uri {
    my ($self) = @_;
    return $self->{_uri} //= Trog::OpenStack::Config->load( $self->cloud )->{auth_url};
}

=head2 network, floating_network, availability_zone, security_group, keypair

Return the values that F<hypervisors.conf> set for new guests.
C<security_group> defaults to C<default>, which is the group that every project
has.  The others have no default, because there is no safe guess for a network.

What size a guest is is not the block's to say: a guest names its flavor in its
C<_global>, as C<openstack_flavor>, and one that names none is not built here.
See L<Trog::HV/size_key> and L</shortfalls(%needs)>.

What a guest boots is not the block's to say: see L</image_for_distro($distro)>.

=head2 image_for_distro($distro)

The id of the newest active Glance image whose C<os_distro> and C<os_version>
properties are the distro's C<distribution> and C<release_version>.  Those are
the properties Glance defines for saying what an image is, and the images a
cloud offers set them.  A snapshot is never the answer, though it inherits them
from the image it was taken of.

Dies when the cloud has no such image, naming the two properties to set on one.

=cut

sub network           ($self) { return $self->setting('network') }
sub floating_network  ($self) { return $self->setting('floating_network') }
sub availability_zone ($self) { return $self->setting('availability_zone') }
sub keypair           ($self) { return $self->setting('keypair') }
sub security_group    ($self) { return $self->setting('security_group') // 'default' }

sub image_for_distro {
    my ( $self, $distro ) = @_;

    my %wanted = ( os_distro => $distro->distribution, os_version => $distro->release_version );
    my ($image) =
      reverse sort { ( $a->{created_at} // q{} ) cmp ( $b->{created_at} // q{} ) }
      grep { ref $_ && ( $_->{status} // q{} ) eq 'active' && ( $_->{image_type} // q{} ) ne 'snapshot' } $self->api->list_images(%wanted);

    return $image->{id} if $image;
    die $self->describe . " has no active image with os_distro=$wanted{os_distro} and os_version=$wanted{os_version}.\n" . "Set those properties on the image guests should boot from:\n" . "    openstack image set --property os_distro=$wanted{os_distro} --property os_version=$wanted{os_version} IMAGE\n";
}

=head1 THE API

=head2 api

Returns the authenticated L<OpenStack::MetaAPI> object, and keeps it for later
calls.

It is built at first use and not in the constructor.  So an object that never
calls the cloud never needs a credential.

=cut

sub api {
    my ($self) = @_;
    return $self->{_api} if $self->{_api};

    my $auth = Trog::OpenStack::Auth->from_cloud( $self->cloud );

    # Without an auth object, MetaAPI builds its own, and that one cannot use
    # application credentials.
    return $self->{_api} = OpenStack::MetaAPI->new( { auth => $auth } );
}

=head2 cheapest_for(%needs)

The smallest flavor this cloud has that holds a guest wanting C<memory_mb>,
C<cpus> and C<disk_bytes>, as L<Trog::HV/cheapest_for(%needs)> returns one,
with a cost of 0.

Smallest rather than cheapest, because Nova gives a flavor no price: what a
project pays for one is between it and whoever runs the cloud, and
L<Trog::HV/monthly_cost(%needs)> answers 0 for the same reason.

A flavor is only offered when the project's quota has room for it, and when it
is at least the C<min_disk> and C<min_ram> of the image the guest boots.  Nova
refuses both, and an offer nobody can accept is worse than none.  Undef when
nothing left holds the guest, or when the cloud cannot be asked.

=cut

sub cheapest_for {
    my ( $self, %needs ) = @_;

    my $image = eval { $self->image_for(%needs) } // {};
    my $have  = eval { $self->capacity };
    return undef unless $have;

    my @fit = eval {
        grep {
                 ref $_
              && ( $_->{ram}   // 0 ) >= ( $needs{memory_mb} // 0 )
              && ( $_->{vcpus} // 0 ) >= ( $needs{cpus}      // 0 )
              && ( $_->{disk}  // 0 ) * $GB >=
              ( $needs{disk_bytes} // 0 )

              # What the image asks of what it is booted on.
              && ( $_->{disk} // 0 ) >= ( $image->{min_disk} // 0 )
              && ( $_->{ram} // 0 ) >=
              ( $image->{min_ram} // 0 )

              # And what the project has left, since an offer the quota would
              # refuse is one nobody can accept.
              && ( !defined $have->{memory_free} || $_->{ram} <= $have->{memory_free} )
              && ( !defined $have->{cpus_free}   || $_->{vcpus} <= $have->{cpus_free} )
        } $self->api->flavors_detail;
    };
    return undef unless @fit;

    my ($smallest) = sort { $a->{ram} <=> $b->{ram} || $a->{vcpus} <=> $b->{vcpus} || $a->{disk} <=> $b->{disk} } @fit;
    return { key => $self->size_key, value => $smallest->{name} // $smallest->{id}, monthly_cost => 0 };
}

=head1 CAPACITY

A quota is what the project is allowed and what it already uses.  L<Trog::HV>
does the arithmetic.  This backend only returns the numbers in the form that
L<Trog::HV> reads.

=head2 max_guests

Returns the value from F<hypervisors.conf> if it is set, or the instance quota
if it is not.

The cloud enforces its instance quota, whatever this tool decides.

=cut

sub max_guests {
    my ($self) = @_;
    return $self->{max_guests} if $self->{max_guests};
    return $self->capacity->{guests_allowed} // 0;
}

=head2 shortfalls(%needs)

As L<Trog::HV/shortfalls(%needs)>, and one more: a guest that names no
C<openstack_flavor> is not built here at all, which is how a guest is kept off
this cloud on purpose.

=cut

sub shortfalls {
    my ( $self, %needs ) = @_;

    my $named = $needs{ $self->size_key };
    return 'names no openstack_flavor, so it is not built on this cloud' unless $named;

    my $flavor = eval { $self->flavor_for(%needs) };
    return "names the flavor '$named', which this cloud has not got" unless $flavor;

    # What the guest gets is the flavor, so that is what its memory, vCPUs and
    # disk are measured against -- and what the project's quota pays for.
    my @reasons;
    push @reasons, sprintf( 'wants %dMB of memory, and %s has %dMB', $needs{memory_mb}, $named, $flavor->{ram} )
      if ( $needs{memory_mb} // 0 ) > ( $flavor->{ram} // 0 );
    push @reasons, sprintf( 'wants %d vCPUs, and %s has %d', $needs{cpus}, $named, $flavor->{vcpus} )
      if ( $needs{cpus} // 0 ) > ( $flavor->{vcpus} // 0 );
    push @reasons, sprintf( 'wants %dGB of disk, and %s has %dGB', ( $needs{disk_bytes} // 0 ) / $GB, $named, $flavor->{disk} // 0 )
      if ( $needs{disk_bytes} // 0 ) > ( $flavor->{disk} // 0 ) * $GB;

    # And what the image asks of whatever it is booted on, which Nova refuses
    # a flavor under: "Flavor's disk is smaller than the minimum size specified
    # in image metadata".
    my $image = eval { $self->image_for(%needs) };
    if ($image) {
        push @reasons, sprintf( 'boots an image that needs %dGB of disk, and %s has %dGB', $image->{min_disk}, $named, $flavor->{disk} // 0 )
          if ( $image->{min_disk} // 0 ) > ( $flavor->{disk} // 0 );
        push @reasons, sprintf( 'boots an image that needs %dMB of memory, and %s has %dMB', $image->{min_ram}, $named, $flavor->{ram} // 0 )
          if ( $image->{min_ram} // 0 ) > ( $flavor->{ram} // 0 );
    }

    return ( @reasons, $self->SUPER::shortfalls( %needs, memory_mb => $flavor->{ram}, cpus => $flavor->{vcpus}, disk_bytes => 0 ) );
}

=head2 capacity

As L<Trog::HV/capacity(%needs)>.  Memory, cores and instances are the project's
Nova quota, and what it has already spent of it.  A quota that is unlimited
comes back undef rather than as the C<-1> Nova reports it as, which is not an
amount to subtract from: a project with an unlimited quota has room for
anything, and arithmetic on C<-1> says it has room for nothing.

C<disk_free> is undef.  A guest here boots from an image onto the disk of its
flavor, so nothing it needs comes out of the Cinder quota, and refusing a guest
for want of block storage it never asks for is how a project with no volume
quota came to be unable to build anything.  L</create_volume($domain, $purpose,
size_gb =E<gt> $n)> is what spends that quota, and nothing in a provision calls
it.

The result is kept for the life of the object, as in the libvirt backend.

=cut

sub capacity {
    my ($self) = @_;
    return $self->{capacity} if $self->{capacity};

    my $nova = $self->api->limits->{absolute} // {};

    my $memory_mb   = _limit( $nova->{maxTotalRAMSize} );
    my $memory_used = $nova->{totalRAMUsed} // 0;
    my $cpus        = _limit( $nova->{maxTotalCores} );
    my $cpus_used   = $nova->{totalCoresUsed} // 0;

    return $self->{capacity} = {
        memory_mb        => $memory_mb,
        memory_committed => $memory_used,
        memory_free      => defined $memory_mb ? $memory_mb - $memory_used - $self->reserve_memory : undef,
        cpus             => $cpus,
        cpus_allocatable => $cpus,
        cpus_committed   => $cpus_used,
        cpus_free        => defined $cpus ? $cpus - $cpus_used - $self->reserve_cpus : undef,
        disk_free        => undef,
        guests           => $nova->{totalInstancesUsed} // 0,

        # Not part of what Trog::HV reads.  max_guests uses it.
        guests_allowed => _limit( $nova->{maxTotalInstances} ),
    };
}

# A quota Nova reports as -1 is unlimited, and undef is how that is said here.
sub _limit {
    my ($value) = @_;
    return undef if !defined $value || $value < 0;
    return $value;
}

=head2 image_for(%needs)

The image a guest of this C<distro> boots, as the cloud describes it, or undef
when there is none.  L</image_for_distro($distro)> answers which it is; this
answers what it is, because an image says the least it can be booted on in its
C<min_disk> and C<min_ram>, and Nova refuses a flavor under either.

=cut

sub image_for {
    my ( $self, %needs ) = @_;

    my $distro  = eval { Provisioner::Cookbook->load( $needs{distro} // 'ubuntu' ) } or return undef;
    my $id      = eval { $self->image_for_distro($distro) }                          or return undef;
    my ($image) = grep { ref $_ && ( $_->{id} // q{} ) eq $id } $self->api->list_images( os_distro => $distro->distribution, os_version => $distro->release_version );

    return $image;
}

=head2 flavor_for(%needs)

The flavor the guest named in C<openstack_flavor>, as the cloud describes it,
or undef when the cloud has no such flavor.

=cut

sub flavor_for {
    my ( $self, %needs ) = @_;

    my $named = $needs{ $self->size_key } or return undef;
    my ($flavor) = grep { ref $_ && ( ( $_->{name} // q{} ) eq $named || ( $_->{id} // q{} ) eq $named ) } $self->api->flavors_detail;

    return $flavor;
}

=head1 GUESTS

A guest is a Nova server whose name is the domain name.  libvirt uses the same
name for a domain.

=head2 server($name)

Returns the server called C<$name>, or nothing.

Dies when C<$name> is empty.  Dies when the cloud has more than one server with
that name, because two servers with one domain name is a problem to report, not
to guess at.

=cut

sub server {
    my ( $self, $name ) = @_;

    die "server() needs a name\n" unless $name;

    # MetaAPI filters for an exact match on our side.  The Nova name filter is a
    # regex, and also matches a guest whose name only starts with $name.
    my @found = grep { ref $_ } $self->api->servers( name => $name );

    die "The cloud has " . scalar(@found) . " servers called '$name'; refusing to guess which\n"
      if @found > 1;

    return $found[0];
}

=head2 server_detail($name)

Returns the full record of the server called C<$name>, or nothing.  Dies as
L</server($name)> does.

The Nova server I<list> returns only C<id>, C<name> and C<links>.  It gives no
status, no addresses and no metadata.  To get those, this makes a second request
by id.

=cut

sub server_detail {
    my ( $self, $name ) = @_;

    my $summary = $self->server($name);
    return unless $summary;

    return $self->api->server_from_uid( $summary->{id} );
}

=head2 guest_names

Returns the name of every server in the project, whatever built it.

An orphan sweep asks whether anything still uses a name.  A server that somebody
else created still uses its name, so the list includes it.

=cut

sub guest_names {
    my ($self) = @_;
    return map { $_->{name} } grep { ref $_ } $self->api->servers();
}

=head2 domain_exists($name)

Returns 1 if there is a guest called C<$name>, in any Nova state, and 0 if there
is not.

=cut

sub domain_exists ( $self, $name ) { return defined $self->server($name) ? 1 : 0 }

=head2 guest_ssh_ip($config, $lease)

Returns the IPv4 address to reach a guest at.  C<$config> is the configuration
of the domain, or the domain name.  C<$lease> is for libvirt, and this backend
ignores it.

A floating IP comes first.  If there is none, an address on an external network
is used.  A fixed address on a tenant network only routes inside that network,
so it is of no use.

Dies when there is no such guest.  Dies with the name of the guest when it has
no reachable address, and does not return an address that never connects.

=cut

sub guest_ssh_ip {
    my ( $self, $config, $_lease ) = @_;

    # The lease is taken and ignored, so bin/provision calls either backend the
    # same way.
    my $name = ref $config ? $config->param('domain') : $config;

    my $server = $self->server_detail($name)
      or die "There is no guest called '$name' on " . $self->describe . "\n";

    my @addresses = grep { _is_ipv4($_) } $self->_addresses($server);

    my $floating = first { ( $_->{'OS-EXT-IPS:type'} // '' ) eq 'floating' } @addresses;
    return $floating->{addr} if $floating;

    # Some clouds have only an external shared network.  Nova calls an address
    # on it 'fixed', but the guest is reachable there.
    my $reachable = first { $self->_network_is_external( $_->{network} ) } @addresses;
    return $reachable->{addr} if $reachable;

    die "The guest '$name' has no address we can reach it at.\n" . "It is on " . ( join( ', ', map { "$_->{network} ($_->{addr})" } @addresses ) || 'no network' ) . ", none of which is external.\n" . "Set floating_network in hypervisors.conf so a routable address gets attached.\n";
}

# Nova gives a hash of network name to a list of addresses.  This flattens it to
# one list, with the network name in each address.
sub _addresses {
    my ( $self, $server ) = @_;

    my $addresses = $server->{addresses};
    return () unless ref $addresses eq 'HASH';

    return map {
        my $network = $_;
        map {
            { %$_, network => $network }    ## no critic (ValuesAndExpressions::ProhibitCommaSeparatedStatements) -- an anonymous hash, which PPI reads as a block
        } @{ $addresses->{$network} }
    } sort keys %$addresses;
}

# The rest of this toolkit uses IPv4 only.  The 'ips' in provision.conf is a
# list of IPv4 addresses, so it cannot hold an IPv6 one.
sub _is_ipv4 ($address) { return ( $address->{addr} // '' ) =~ m/\A\d+(?:[.]\d+){3}\z/ ? 1 : 0 }

# Whether the outside world can route to this network.  The answer is cached,
# because guest_ssh_ip asks again and again while a guest starts.
sub _network_is_external {
    my ( $self, $name ) = @_;

    return 0 unless $name;
    return $self->{_external}{$name} if exists $self->{_external}{$name};

    my ($network) = grep { ref $_ && ( $_->{name} // '' ) eq $name } $self->api->networks();

    return $self->{_external}{$name} = ( $network && $network->{'router:external'} ) ? 1 : 0;
}

=head1 SNAPSHOTS

Nova makes a snapshot of a server as a Glance image.  Glance images belong to
the project, not to a server.  So the name of each snapshot image holds the
guest name, as C<$domain@$snapshot>.  No domain name and no libvirt snapshot
name contains C<@>.

=head2 snapshot_names($domain)

Returns the names of the snapshots of this guest, newest first.

=cut

sub snapshot_names {
    my ( $self, $domain ) = @_;

    # Glance filters on image_type, which Nova sets on every snapshot, so base
    # images do not come back.  Glance matches a name only exactly, so the
    # prefix for one guest is filtered here.
    my @images =
      reverse sort { ( $a->{created_at} // '' ) cmp ( $b->{created_at} // '' ) }
      grep { ref $_ && index( $_->{name} // '', "$domain\@" ) == 0 } $self->api->list_images( image_type => 'snapshot' );

    return map { substr $_->{name}, length("$domain\@") } @images;
}

=head2 create_snapshot($domain, $name, disk_only =E<gt> $bool)

Takes a snapshot of the guest while it runs, and returns 1.  Dies when there is
no such guest.

C<disk_only> is accepted and ignored.  The libvirt backend uses it to choose
between a snapshot with memory and one of the disk only.  Nova never saves
memory, and does not need to stop the guest.

=cut

sub create_snapshot {
    my ( $self, $domain, $name, %opts ) = @_;

    my $server = $self->server($domain)
      or die "There is no guest called '$domain' to snapshot\n";

    $self->api->create_image( $server->{id}, name => "$domain\@$name" );
    return 1;
}

=head2 revert_snapshot($domain, $name)

Puts the guest back on a snapshot, and returns 1.  This is a Nova rebuild onto
the snapshot image.  The server, its addresses and its floating IP stay.  The
contents of the root disk change.

Dies when there is no such guest, or no such snapshot.

=cut

sub revert_snapshot {
    my ( $self, $domain, $name ) = @_;

    my $server = $self->server($domain)
      or die "There is no guest called '$domain' to revert\n";

    # Glance finds an exact name without a list of every image.
    my $image = $self->api->image_from_name("$domain\@$name");
    $image = $image->[0] if ref $image eq 'ARRAY';

    die "The guest '$domain' has no snapshot called '$name'\n"
      unless ref $image eq 'HASH' && $image->{id};

    $self->api->server_action( $server->{id}, { rebuild => { imageRef => $image->{id} } } );
    return 1;
}

=head1 BUILDING AND TEARING DOWN

=head2 create_guest(%spec)

Builds a guest, and waits until Nova reports it C<ACTIVE>.  If there is a
C<floating_network>, it also attaches a floating IP from that network.

C<name> is required, and so is C<image>, which L</image_for_distro($distro)>
answered when F<bin/new_config> wrote the guest's F<provision.conf>, and
C<size>, the flavor it names in C<openstack_flavor>.  C<flavor> is that same
value under Nova's name for it.  C<network>,
C<network>, C<floating_network>, C<availability_zone>, C<security_group> and
C<keypair> each default to the value in F<hypervisors.conf>.

C<user_data> is the cloud-init payload.  Nova takes it as a field on the server,
in place of the C<cidata> ISO.

The Nova metadata of the guest gets C<managed_by> and C<domain>, on top of any
C<metadata> that the caller passes.

Returns the server.  It includes C<floating_ip_address> when a floating IP was
attached.

Dies when C<name>, C<size>, C<image> or C<network> has no value.  Dies when
the server does not become C<ACTIVE>.

=cut

sub create_guest {
    my ( $self, %spec ) = @_;

    my $name = $spec{name};
    die "create_guest needs a name\n" unless $name;

    # floating_network is not required.  A cloud whose only network is external
    # needs no floating IP, and guest_ssh_ip reports a guest it cannot reach.
    die "Building '$name' on " . $self->describe . " needs an image, which the distro recipe decides\n" unless $spec{image};
    $spec{flavor} //= $spec{size};
    foreach my $needed (qw{flavor network}) {
        $spec{$needed} //= $self->setting($needed);
        die "Building '$name' on " . $self->describe . " needs '$needed'.\n" . "Set it in the cloud's block in hypervisors.conf, or pass it here.\n"
          unless $spec{$needed};
    }

    $spec{floating_network} //= $self->floating_network;

    my @optional;
    push @optional, ( key_name => $spec{keypair} // $self->keypair )
      if defined( $spec{keypair} // $self->keypair );
    push @optional, ( availability_zone => $spec{availability_zone} // $self->availability_zone )
      if defined( $spec{availability_zone} // $self->availability_zone );
    push @optional, ( user_data => $spec{user_data} )
      if $spec{user_data};
    push @optional, ( network_for_floating_ip => $spec{floating_network} )
      if $spec{floating_network};

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

=head2 rebuild_guest($name, image => $image, user_data => $seed)

Puts a new root disk from the image under a guest that exists, with a new
cloud-init payload.  Then waits until Nova reports it C<ACTIVE> again.

A rebuild keeps the server, its ports, its floating IP and its attached volumes.
It replaces the root disk, as a libvirt rebuild makes the overlay again from the
base image.  C<image> is required: the guest's own, from its F<provision.conf>,
as in L</create_guest(%spec)>.

The payload holds the key that F<bin/provision> just added.  Without it, the
guest starts with a payload that does not let us in.  So this asks Nova for the
microversion that takes C<user_data>, and an older cloud refuses the request.

Returns the full server record.

Dies when there is no such guest, no image, or no image with that name.  Dies
when the server goes to C<ERROR>, or is not C<ACTIVE> after
C<$REBUILD_TIMEOUT> seconds.

=cut

sub rebuild_guest {
    my ( $self, $name, %spec ) = @_;

    my $server = $self->server($name)
      or die "There is no guest called '$name' to rebuild\n";

    my $image = $spec{image};
    die "Rebuilding '$name' on " . $self->describe . " needs an image, which the distro recipe decides\n" unless $image;

    my %rebuild = ( imageRef => $self->_image_id($image) );
    $rebuild{user_data} = MIME::Base64::encode_base64( $spec{user_data}, '' )
      if $spec{user_data};

    $self->_nova( POST => "/servers/$server->{id}/action", { rebuild => \%rebuild }, $REBUILD_MICROVERSION );

    return $self->_wait_for_active( $server->{id}, $name );
}

# The Nova rebuild takes an image id, and a provision.conf written before
# image_for_distro answered with one can name the image.
sub _image_id {
    my ( $self, $image ) = @_;

    return $image if $image =~ m/\A[[:xdigit:]]{8}(?:-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}\z/;

    my $found = $self->api->image_from_name($image);
    $found = $found->[0] if ref $found eq 'ARRAY';

    die "There is no image called '$image' on " . $self->describe . "\n"
      unless ref $found eq 'HASH' && $found->{id};

    return $found->{id};
}

# A call to Nova at a microversion.  The post in MetaAPI sends no version
# header, so Nova treats it as 2.1, whose rebuild takes no user_data.
sub _nova {
    my ( $self, $method, $path, $body, $microversion ) = @_;

    my $compute = $self->api->route->service('compute');
    my %headers = defined $microversion ? ( 'OpenStack-API-Version' => "compute $microversion" ) : ();

    return $compute->client->call( $method, \%headers, $compute->root_uri($path), $body );
}

# Waits until Nova finishes with the server.  ACTIVE with a task still set is a
# rebuild that did not start yet.  ERROR does not change, so it dies at once.
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

=head2 annihilate_domain($name)

Deletes the guest, and the volumes that this tool made for it.

A volume counts as ours when its name starts with C<$name->, which is how
L</create_volume($domain, $purpose, size_gb =E<gt> $n)> names it.  This leaves
every other volume alone, because a wrong guess destroys data.

This does not delete the floating IP of the guest.

Returns 0 when there was no such guest, so it is safe to call on a name that is
already gone.  Returns 1 otherwise.

Dies when the server is still there after C<$DELETE_TIMEOUT> seconds.  Warns,
and continues, when a volume does not delete.

=cut

sub annihilate_domain {
    my ( $self, $name ) = @_;

    my $server = $self->server($name);
    return 0 unless $server;

    my @ours = grep { index( $_->{name} // '', "$name-" ) == 0 } $self->_volumes;

    $self->api->delete_server( $server->{id} );

    # Cinder refuses to delete a volume while it is attached to a server that
    # Nova has not finished deleting.
    $self->_wait_for_gone($name);

    foreach my $volume (@ours) {
        my $ok = eval { $self->api->delete_volume( $volume->{id} ); 1 };
        warn "Could not delete the volume $volume->{name} ($volume->{id}): $@" unless $ok;
    }

    return 1;
}

# Waits until the server is gone.  A server stuck in ERROR looks slow until the
# wait runs out, so the message says to check its status.
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

=head2 create_volume($domain, $purpose, size_gb =E<gt> $n)

Creates a Cinder volume called C<$domain-$purpose>, so that teardown can find
it.  C<extra> is a hash of more fields for Cinder.  Returns what Cinder returns.

Dies when C<size_gb> is not given.

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

# MetaAPI returns a single volume for a list of one, and undef for an empty list.
sub _volumes {
    my ($self) = @_;
    return grep { ref $_ } $self->api->volumes();
}

=head1 WHAT THIS CANNOT DO

L<Trog::HV::Cloud/WHAT THIS CANNOT DO> refuses the libvirt terms that have no
match on a cloud.  This says why in OpenStack's own terms.

=head2 refusals

As L<Trog::HV::Cloud/refusals>, with the reasons that Nova, Glance, Cinder and
Neutron make more precise.

=cut

sub refusals {
    my ($self) = @_;
    return (
        $self->SUPER::refusals,
        define_domain      => 'a Nova server is not defined from libvirt XML -- use create_guest',
        cloudinit_iso      => 'Nova takes cloud-init as user_data, so there is no ISO to build',
        base_image         => 'a root disk comes from a Glance image, not a downloaded file',
        create_disk        => 'a disk is a Cinder volume -- use create_volume',
        lease_ip           => 'Neutron assigns addresses; there is no lease table',
        release_dhcp_lease => 'Neutron assigns addresses; there is no lease to release',
        guest_mac          => 'Neutron assigns the MAC, so it cannot be derived from the name',
        nic_names          => 'interface names come from Neutron and cloud-init, not from a PCI slot',
        has_tpm            => 'a TPM is a property of the flavor or image, not of a host',
    );
}

=head1 PROVISIONING

=head2 @names = $hv->preflight_checks(), $hv->preflight_notes()

Return the names of the checks and notes that C<bin/preflight> runs on this
backend, in order.  See L<Trog::HV/PREFLIGHT>.

=cut

sub preflight_checks { return qw{check_reachable check_cloud_resources check_cloud_quota check_rsync check_transfer_ip check_fetch_sources check_config} }
sub preflight_notes  { return qw{note_stale_image note_apt_mirror note_plaintext_secrets} }

=head2 $result = $hv->check_reachable()

Makes sure that the credential in F<clouds.yaml> gets a token, and that the
catalog has compute, image and network.  The other checks need this to pass.

=cut

sub check_reachable {
    my ($self) = @_;

    my @services = eval { $self->api->auth->services };
    return $self->_verdict( 0, 'Could not authenticate to ' . $self->describe, <<"FIX" ) unless @services;
$@
The cloud is named '@{[ $self->cloud ]}', so this is the entry of that name in
clouds.yaml.  Check the application credential has not been revoked or expired:

    openstack --os-cloud @{[ $self->cloud ]} token issue
FIX

    my %offered = map  { $_ => 1 } @services;
    my @missing = grep { !$offered{$_} } qw{compute image network};

    return $self->_verdict( 0, 'The catalog is missing: ' . join( ', ', @missing ), <<'FIX' ) if @missing;
A guest needs Nova to run on, Glance to boot from and Neutron to be addressed
on.  A credential scoped to a project without all three cannot build one.
FIX

    return $self->_verdict( 1, 'Authenticated; the catalog offers ' . scalar(@services) . ' services', q{} );
}

=head2 $result = $hv->check_cloud_resources()

Makes sure that the network in F<hypervisors.conf>, and the floating network if
one is set, exist on this cloud, that it has every flavor the guests name in
C<openstack_flavor>, and an image for each distro the configuration uses.  A wrong name otherwise fails a provision
minutes later, with an error from the API.

=cut

sub check_cloud_resources {
    my ($self) = @_;

    my %wanted = ( network => $self->network );
    $wanted{floating_network} = $self->floating_network if defined $self->floating_network;

    my @unset = grep { !$wanted{$_} } sort keys %wanted;
    return $self->_verdict( 0, 'Not configured: ' . join( ', ', @unset ), <<'FIX' ) if @unset;
The cloud's block in hypervisors.conf has to say what to build guests as.  What
exists is the cloud's to say, so ask it rather than guessing:

    openstack flavor list
    openstack image list
    openstack network list
FIX

    my %found;
    $found{network}          = eval { scalar $self->api->look_by_id_or_name( networks => $wanted{network} ) };
    $found{floating_network} = eval { scalar $self->api->look_by_id_or_name( networks => $wanted{floating_network} ) }
      if exists $wanted{floating_network};

    my @absent = grep { !$found{$_} } sort keys %found;
    return $self->_verdict( 0, 'The cloud has no ' . join( ', ', map { "$_ '$wanted{$_}'" } @absent ), <<'FIX' ) if @absent;
Ask the cloud what it has:

    openstack flavor list
    openstack image list
    openstack network list
FIX

    my ( @images, @no_image );
    foreach my $distro ( $self->distros_in_use ) {
        my $image = eval { $self->image_for_distro($distro) };
        $image ? push( @images, $image ) : push( @no_image, $@ );
    }
    return $self->_verdict( 0, 'The cloud has no image for ' . scalar(@no_image) . ' distro(s) in use', join( "\n", @no_image ) ) if @no_image;

    my @flavors = $self->globals_in_use( $self->size_key );
    my @missing = grep {
        !eval { scalar $self->api->look_by_id_or_name( flavors => $_ ) }
    } @flavors;
    return $self->_verdict( 0, 'The cloud has no flavor ' . join( ', ', map { "'$_'" } @missing ), "Ask the cloud what it has:\n\n    openstack flavor list\n" ) if @missing;

    return $self->_verdict( 1, 'Builds from ' . join( ', ', @images ) . " on $wanted{network}" . ( @flavors ? ', as ' . join( ', ', @flavors ) : ', and no guest names an openstack_flavor yet' ), q{} );
}

=head2 $result = $hv->check_cloud_quota()

Makes sure that the quota has room for one more guest: an instance, memory and
cores.  On a cloud, the quota takes the place of hardware limits.  A quota that
is unlimited is never full, and says so rather than reading as empty.

=cut

sub check_cloud_quota {
    my ($self) = @_;

    my $have = eval { $self->capacity };
    return $self->_verdict( 0, 'Could not read the quota for ' . $self->describe, "$@" ) unless $have;

    # An undefined free is a quota with no limit in it, which is never full.
    my @full;
    push @full, 'instances' if $self->max_guests            && $have->{guests} >= $self->max_guests;
    push @full, 'memory'    if defined $have->{memory_free} && $have->{memory_free} <= 0;
    push @full, 'cpus'      if defined $have->{cpus_free}   && $have->{cpus_free} <= 0;

    return $self->_verdict( 0, 'No quota left for: ' . join( ', ', @full ), <<"FIX" ) if @full;
The project holds @{[ $have->{guests} ]} of @{[ $self->max_guests || 'unlimited' ]} instances,
@{[ $have->{memory_committed} ]}MB of @{[ $have->{memory_mb} // 'unlimited' ]}MB of memory and
@{[ $have->{cpus_committed} ]} of @{[ $have->{cpus} // 'unlimited' ]} cores.

Destroy a guest you have finished with, or ask for more quota.  Note that the
reserves in hypervisors.conf are held back out of the quota, so a project that
looks like it has room may not once they are counted.
FIX

    return $self->_verdict(
        1,
        sprintf(
            'Quota: %s/%s instances used, %s of memory and %s cores free',
            $have->{guests}, $self->max_guests || 'unlimited',
            defined $have->{memory_free} ? $have->{memory_free} . 'MB' : 'unlimited memory',
            $have->{cpus_free} // 'unlimited'
        ),
        q{}
    );
}

=head1 SEE ALSO

L<Trog::HV>, which chooses this backend and does the placement arithmetic.

L<Trog::HV::Cloud>, which provisions a guest from what this backend's calls
return, and answers what every backend that builds by API answers the same way.

L<Trog::OpenStack::Auth>, which authenticates it.

L<Trog::HV::Libvirt>, the other backend.

=cut

1;
