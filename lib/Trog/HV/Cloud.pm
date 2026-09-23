package Trog::HV::Cloud;

#ABSTRACT: what every backend that asks a service for its guests has in common.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::HV';

use Provisioner::Cookbook();
use Trog::Config();

=head1 NAME

Trog::HV::Cloud - what every backend that asks a service for its guests has in
common

=head1 SYNOPSIS

    package Trog::HV::Example;
    use parent 'Trog::HV::Cloud';

    # Then the backend's own: build, config_keys, describe, capacity,
    # domain_exists, guest_names, guest_ssh_ip, create_guest, rebuild_guest,
    # annihilate_domain, the snapshots, preflight_checks, preflight_notes and
    # check_reachable.

=head1 DESCRIPTION

A backend under this class builds its guests by asking an API, as
L<Trog::HV::OpenStack> asks Nova.  It is not a backend itself, and
L<Trog::HV/backend_for(%opts)> never chooses it.

What a backend like that answers the same way whichever service it asks is
here: that there is no machine to reach, no host to prepare, no seed drive, no
address pool and no libvirt noun.  So is the way a guest gets provisioned: the
service creates it or rebuilds it with the seed as its cloud-init payload, and
then says where it is.

A subclass provides the calls to its service.  L</provision_guest($config,
$seed, %opts)> uses three of them:

=over 4

=item * C<create_guest(name =E<gt> $domain, image =E<gt> $image, size =E<gt>
$size, user_data =E<gt> $payload)>, which makes a new guest and returns once it
runs.  C<size> is what the guest named in this backend's C<size_key>.

=item * C<rebuild_guest($domain, image =E<gt> $image, user_data =E<gt> $payload)>,
which puts a new root disk under a guest that exists, keeps its addresses, and
returns once it runs again.

=item * C<guest_ssh_ip($config)>, the address at which we reach the guest.

=back

=head1 IDENTITY

=head2 is_local

True, but not because the service is this machine.

There is no hypervisor filesystem to reach.  So the directory for each domain is
on the machine that runs this tool, and every file operation that
L<Trog::Machine> offers runs locally.

=head2 builds_by_api

True.  The service creates the guest, so a backend here uses none of the
libvirt XML that this toolkit can generate.

=head2 manages_addresses

True.  The service allocates the addresses, and the address pool has no part in
it.

=cut

sub is_local          { return 1 }
sub builds_by_api     { return 1 }
sub manages_addresses { return 1 }

=head2 cpu_overcommit

Returns 1, always.

On a libvirt host, the CPU count is physical, and we decide how many vCPUs per
core are acceptable.  What a service reports is already the number of vCPUs
that we may run.  So there is nothing to overcommit, and a larger ratio gives
headroom that the service refuses.

=cut

sub cpu_overcommit { return 1 }

=head2 inspection_address($domain)

The guest's own address, from the backend's C<guest_ssh_ip>: the service
gives the guest its address and there is no other way in.

=cut

sub inspection_address ( $self, $domain ) { return $self->guest_ssh_ip($domain) }

=head1 NOTHING TO DO

=head2 prepare_host

=head2 release_seed($domain)

=head2 guest_volumes($domain)

Each does nothing, for its own reason.  There is no machine to prepare, because
the service builds the guest and its disk comes from an image.  There is no seed
to release, because the payload is a field on the guest, not a drive.  There are
no volumes left after a guest is gone, because the backend's
C<annihilate_domain> deletes what this tool made.

=cut

sub prepare_host  { return 1 }
sub release_seed  { return 1 }
sub guest_volumes { return () }

=head2 clear_guest($domain)

Does nothing, and returns 1.

The libvirt backend deletes the domain and its disks before it builds them
again.  A service rebuilds the guest that exists, so its addresses and attached
volumes stay.  If this cleared the guest first, those would be lost.

=cut

sub clear_guest { return 1 }

=head1 SNAPSHOTS

=head2 rollback_possible($domain, %opts)

Returns 1 if a snapshot taken now survives the rebuild, and 0 if it does not.
A snapshot here is an image the service keeps apart from the guest, and a
rebuild leaves the image alone.  So this only asks whether there is a guest to
snapshot.

C<capacity> is accepted and ignored.  The libvirt backend uses it, because there
the snapshot lives in the disk.

=cut

sub rollback_possible {
    my ( $self, $domain, %opts ) = @_;

    return eval { $self->domain_exists($domain) } ? 1 : 0;
}

=head2 snapshot_current_name($domain)

Returns the name of the newest snapshot of this guest.

libvirt records which snapshot a domain is on.  A service has no such record,
so this is the first of the backend's C<snapshot_names>, which come newest
first.

=cut

sub snapshot_current_name {
    my ( $self, $domain ) = @_;

    my ($newest) = $self->snapshot_names($domain);
    return $newest;
}

=head1 PROVISIONING

=head2 provision_guest($config, $seed, %opts)

Gets the guest from the service, and returns its address.  If the guest exists,
this rebuilds it.  If not, this creates it.

C<$seed> holds the C<user-data> that C<bin/provision> already wrote, and the
C<image> in C<$config> is what C<image_for_distro> answered when
F<bin/new_config> wrote it.  There is no XML to render and no lease to wait
for.  The service takes the seed
directly, and the address comes back with the guest.  If C<reuse> is true and
the guest exists, this provisions onto it without a rebuild.

Dies as the backend's C<create_guest>, C<rebuild_guest> and C<guest_ssh_ip>
do.

=cut

sub provision_guest {
    my ( $self, $config, $seed, %opts ) = @_;

    my $domain = $config->param('domain');
    my $image  = $config->param('image');

    # What the guest is here, by this backend's name for a size: the value of
    # its size_key, which bin/new_config wrote into provision.conf.
    my %size     = $self->size_key ? ( size => scalar $config->param( $self->size_key ) ) : ();
    my $existing = $self->domain_exists($domain);

    if ( $existing && $opts{reuse} ) {
        print "$domain is already on " . $self->describe . "; provisioning onto it\n";
    }
    elsif ($existing) {
        print 'Asking ' . $self->describe . " to rebuild $domain...\n";
        $self->rebuild_guest( $domain, image => $image, %size, user_data => $seed->{'user-data'} );
    }
    else {
        print 'Asking ' . $self->describe . " for $domain...\n";
        $self->create_guest( name => $domain, image => $image, %size, user_data => $seed->{'user-data'} );
    }

    my $ip = $self->guest_ssh_ip($config);
    print "$domain is at $ip\n";

    return $ip;
}

=head2 $hv->would_provision($config, %opts)

Prints what C<provision_guest> does, without doing it.  Returns the address of
a guest that exists, or C<(not built)>.

=cut

sub would_provision {
    my ( $self, $config, %opts ) = @_;

    my $domain   = $config->param('domain');
    my $existing = $self->domain_exists($domain);
    my $doing    = !$existing ? 'build' : $opts{reuse} ? 'reprovision' : 'rebuild';

    print "Would $doing $domain on " . $self->describe . "\n";

    return $existing ? $self->guest_ssh_ip($config) : '(not built)';
}

=head1 PREFLIGHT

=head2 $result = $hv->check_transfer_ip()

Makes sure that a C<transfer_ip> is named, in the block of this hypervisor in
F<hypervisors.conf> or in the C<_global> of F<recipes.yaml>.
A service assigns the guest address only when it creates the guest, after the
seed is written.  So the address cannot be found the way libvirt finds it.  See
L<Trog::HV/PREFLIGHT>.

=cut

sub check_transfer_ip {
    my ($self) = @_;

    my $rfile = Trog::Config->path('recipes.yaml');
    my $named = $self->configured_transfer_ip // eval { Provisioner::Cookbook->globals(undef)->{transfer_ip} };

    return $self->_verdict( 1, "Guests fetch their payload from $named", q{} ) if $named;

    return $self->_verdict( 0, 'No transfer_ip, and a cloud cannot be asked for one', <<"FIX" );
A guest scps its payload and rsyncs its data directory out of this machine, so
it needs an address here that it can get to.  On a hypervisor that address is
worked out by asking the routing table about the guest's network -- but
@{[ $self->describe ]} allocates a guest's address when it creates it, so there is
nothing to ask about until the guest exists, and the seed naming the address is
written before that.

Name it in the block of this hypervisor in hypervisors.conf:

    transfer_ip   = 192.0.2.10
    transfer_port = 2222

or, for every hypervisor, in the _global of _base in $rfile:

    transfer_ip: 192.0.2.10

It has to be an address of this machine that a guest on the cloud can reach,
and transfer_port the port that reaches this machine's sshd there, when a
gateway forwards another one to it.
FIX
}

=head1 WHAT THIS CANNOT DO

These are libvirt terms that have no match on a service that builds guests by
API.  Each one dies with its own name and the reason, from C<refusals>.  It
does not return undef, which a caller can carry somewhere else before it fails.

=over 4

=item * C<define_domain>, C<cloudinit_iso>, C<eject_cdrom>: the guest is not
built from libvirt XML, and takes cloud-init as C<user_data>.  So there is no
XML to define and no ISO to attach.

=item * C<pool_path>, C<pool_target>, C<base_image>, C<create_disk>: there is
no storage pool, and no disk image file on a filesystem.

=item * C<lease_ip>, C<release_dhcp_lease>, C<guest_mac>, C<nic_slots>,
C<nic_names>: the service assigns addresses and MACs.  There is no NAT lease
table to read, and no PCI slot to pin an interface to.  So there is no
interface name to derive from a slot.

=item * C<has_tpm>: a TPM is a property of what the service offers, not of a
host.

=back

=head2 %reasons = $hv->refusals()

Returns each refused method paired with the reason it gives.  A backend
overrides the reasons that it can say more precisely, in the terms of its own
service, and keeps the rest:

    sub refusals ($self) { return ( $self->SUPER::refusals, create_disk => 'a disk is a Cinder volume' ) }

=for Pod::Coverage define_domain cloudinit_iso eject_cdrom pool_path pool_target base_image create_disk lease_ip release_dhcp_lease guest_mac nic_slots nic_names has_tpm

=cut

sub refusals {
    return (
        define_domain      => 'a guest here is not defined from libvirt XML -- use create_guest',
        cloudinit_iso      => 'the cloud takes cloud-init as user_data, so there is no ISO to build',
        eject_cdrom        => 'there is no cdrom',
        pool_path          => 'there is no storage pool',
        pool_target        => 'there is no storage pool',
        base_image         => 'a root disk comes from an image of the cloud, not a downloaded file',
        create_disk        => 'a disk is the cloud\'s to make, not a file in a pool',
        lease_ip           => 'the cloud assigns addresses; there is no lease table',
        release_dhcp_lease => 'the cloud assigns addresses; there is no lease to release',
        guest_mac          => 'the cloud assigns the MAC, so it cannot be derived from the name',
        nic_slots          => 'there is no PCI topology to pin an interface to',
        nic_names          => 'interface names come from the cloud and cloud-init, not from a PCI slot',
        has_tpm            => 'a TPM is a property of what the cloud offers, not of a host',
    );
}

# The message names the call and what to use instead, which "method not found"
# does not.
sub _refuse {
    my ( $self, $method ) = @_;

    my %because = $self->refusals;
    die ref($self) . " has no $method: $because{$method}\n";
}

sub define_domain      ( $self, @ ) { return $self->_refuse('define_domain') }
sub cloudinit_iso      ( $self, @ ) { return $self->_refuse('cloudinit_iso') }
sub eject_cdrom        ( $self, @ ) { return $self->_refuse('eject_cdrom') }
sub pool_path          ( $self, @ ) { return $self->_refuse('pool_path') }
sub pool_target        ( $self, @ ) { return $self->_refuse('pool_target') }
sub base_image         ( $self, @ ) { return $self->_refuse('base_image') }
sub create_disk        ( $self, @ ) { return $self->_refuse('create_disk') }
sub lease_ip           ( $self, @ ) { return $self->_refuse('lease_ip') }
sub release_dhcp_lease ( $self, @ ) { return $self->_refuse('release_dhcp_lease') }
sub guest_mac          ( $self, @ ) { return $self->_refuse('guest_mac') }
sub nic_slots          ( $self, @ ) { return $self->_refuse('nic_slots') }
sub nic_names          ( $self, @ ) { return $self->_refuse('nic_names') }
sub has_tpm            ( $self, @ ) { return $self->_refuse('has_tpm') }

=head1 SEE ALSO

L<Trog::HV>, the contract every backend answers.

L<Trog::HV::OpenStack>, a backend built on this one.

=cut

1;
