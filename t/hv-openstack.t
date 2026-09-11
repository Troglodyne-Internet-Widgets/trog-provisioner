#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/hv-openstack.t - Trog::HV::OpenStack: what a cloud answers, and what it
refuses to pretend to

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp();

## no critic (CompileTime) -- it has to be set before anything reads it.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use FindBin::libs;

use Trog::HV();
use Trog::HV::OpenStack();

# Stands in for OpenStack::MetaAPI.  Records what it was asked to do, so the
# assertions can be about the request rather than about a canned reply, and is
# stateful where the code under test waits for state to change.
{

    package Test::FakeCloud;

    sub new {
        my ( $class, %state ) = @_;
        return bless { calls => [], servers => [], images => [], volumes => [], %state }, $class;
    }

    sub _record {
        my ( $self, $what, @args ) = @_;
        push @{ $self->{calls} }, [ $what, @args ];
        return;
    }

    sub calls_to {
        my ( $self, $what ) = @_;
        return grep { $_->[0] eq $what } @{ $self->{calls} };
    }

    sub limits        { return $_[0]->{limits} }
    sub volume_limits { return $_[0]->{volume_limits} }

    sub list_images {
        my ( $self, %query ) = @_;
        $self->_record( list_images => \%query );
        return @{ $self->{images} };
    }

    sub image_from_name {
        my ( $self, $name ) = @_;
        my @hit = grep { ( $_->{name} // '' ) eq $name } @{ $self->{images} };
        return $hit[0];
    }
    sub volumes { return @{ $_[0]->{volumes} } }

    # Nova's server list returns id, name and links and nothing else -- no
    # status, no addresses.  A fake that handed back the whole record would let
    # code pass here that cannot work against a real cloud, which is exactly
    # what happened before this was written this way.
    sub servers {
        my ( $self, %filter ) = @_;
        my @all = @{ $self->{servers} };
        @all = grep { ( $_->{name} // '' ) eq $filter{name} } @all if defined $filter{name};

        my @summaries = map { { id => $_->{id}, name => $_->{name}, links => [] } } @all;

        # And it collapses a single result to a bare hash, returning nothing
        # useful for none, so this has to do that too.
        return $summaries[0] if scalar @summaries <= 1;
        return @summaries;
    }

    sub server_from_uid {
        my ( $self, $uid ) = @_;
        $self->_record( server_from_uid => $uid );
        my ($full) = grep { $_->{id} eq $uid } @{ $self->{servers} };
        return $full;
    }

    sub networks { return @{ $_[0]->{networks} // [] } }

    sub create_vm {
        my ( $self, %opts ) = @_;
        $self->_record( create_vm => \%opts );
        return { id => 'new-uuid', name => $opts{name}, status => 'ACTIVE', floating_ip_address => '203.0.113.9' };
    }

    sub delete_server {
        my ( $self, $uid ) = @_;
        $self->_record( delete_server => $uid );
        @{ $self->{servers} } = grep { $_->{id} ne $uid } @{ $self->{servers} };
        return 1;
    }

    sub delete_volume  { my ( $s, $id ) = @_; $s->_record( delete_volume => $id ); return 1 }
    sub create_volume  { my ( $s, %o )  = @_; $s->_record( create_volume => \%o ); return { id => 'vol-new', %o } }
    sub attach_volume  { my ( $s, @a )  = @_; $s->_record( attach_volume => @a );  return { id => $a[1] } }
    sub create_image   { my ( $s, @a )  = @_; $s->_record( create_image => @a );   return 1 }
    sub server_action  { my ( $s, @a )  = @_; $s->_record( server_action => @a );  return 1 }
    sub console_output { my ( $s, @a )  = @_; $s->_record( console_output => @a ); return "it booted\n" }
}

my $FAKE;
my $mock = Test::MockModule->new('Trog::HV::OpenStack');
$mock->redefine( api => sub { return $FAKE } );

sub cloud {
    my (%opts) = @_;
    Trog::HV->forget();
    return Trog::HV->candidate( cloud => 'testcloud', %opts );
}

subtest 'a cloud has to be named' => sub {
    like exception { Trog::HV::OpenStack->build() }, qr/needs a 'cloud'/,
      'there is no guessing which of somebody\'s clouds was meant';

    my $hv = cloud();
    is ref $hv,       'Trog::HV::OpenStack',           'a cloud block gets the cloud backend';
    is $hv->cloud,    'testcloud',                     'and remembers which';
    is $hv->describe, 'the OpenStack cloud testcloud', 'and says so when a diagnostic asks';

    ok $hv->isa('Trog::HV'),      'it is a hypervisor';
    ok $hv->isa('Trog::Machine'), 'and a machine, which is what makes the local file operations work';
};

subtest 'is_local is true, and why that is not a lie' => sub {
    my $hv = cloud();

    ok $hv->is_local, 'there is no hypervisor filesystem to reach, so the domain dir is here';
    is $hv->domain_dir, '/opt/domains', 'which it gets from Trog::HV like anything else';

    # Which is what makes the payload need nothing special: the guest fetches it
    # from Trog::Local, the same place a libvirt guest does, and there is no
    # hypervisor in that arrangement to be missing.
    ok $hv->isa('Trog::Machine'), 'and its file operations are a machine\'s, aimed here';
};

subtest 'what hypervisors.conf configures' => sub {
    my $hv = cloud(
        flavor           => 'm1.medium',
        image            => 'ubuntu-24.04',
        network          => 'internal',
        floating_network => 'public',
        keypair          => 'buildkey',
    );

    is $hv->flavor,           'm1.medium',    'flavor';
    is $hv->image,            'ubuntu-24.04', 'image';
    is $hv->network,          'internal',     'network';
    is $hv->floating_network, 'public',       'floating_network';
    is $hv->keypair,          'buildkey',     'keypair';
    is $hv->security_group,   'default',      'the security group defaults to the one every project has';

    my %keys = Trog::HV::OpenStack->config_keys;
    is $keys{cloud},  'cloud',  'cloud is read under its own name';
    is $keys{flavor}, 'flavor', 'and so is everything else';
    ok !exists $keys{uri}, 'and a cloud has no libvirt_uri';
};

subtest 'capacity is a quota, which is what makes it capacity' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new(
        limits => {
            absolute => {
                maxTotalRAMSize    => 51200,
                totalRAMUsed       => 32768,
                maxTotalCores      => 40,
                totalCoresUsed     => 20,
                maxTotalInstances  => 10,
                totalInstancesUsed => 4,
            }
        },
        volume_limits => { absolute => { maxTotalVolumeGigabytes => 1000, totalGigabytesUsed => 790 } },
    );

    my $have = $hv->capacity;
    my $GB   = 1024 * 1024 * 1024;

    is $have->{memory_mb},        51200,                               'the allowance is the memory figure, not a physical count';
    is $have->{memory_committed}, 32768,                               'and the usage comes with it';
    is $have->{memory_free},      51200 - 32768 - $hv->reserve_memory, 'less what we hold back';
    is $have->{cpus},             40,                                  'cores';
    is $have->{cpus_allocatable}, 40,                                  'and no overcommit applied to them';
    is $have->{cpus_free},        40 - 20 - $hv->reserve_cpus,         'less the reserve';
    is $have->{disk_free}, ( 1000 - 790 ) * $GB - $hv->reserve_disk, 'disk comes from cinder';
    is $have->{guests},                                              4, 'and the instance count';

    is $hv->cpu_overcommit, 1,
      'overcommit is 1: a quota is already what we may run, so multiplying it invents headroom';

    is $hv->max_guests,                      10, 'the instance quota caps the guest count';
    is cloud( max_guests => 3 )->max_guests, 3,  'unless the configuration is stricter';

    # Trog::HV's arithmetic, over the numbers this backend supplied.
    my @none = $hv->shortfalls( memory_mb => 1024, cpus => 1, disk_bytes => 1 * $GB );
    is scalar @none, 0, 'a guest that fits has no shortfalls';

    my @reasons = $hv->shortfalls( memory_mb => 999999, cpus => 999, disk_bytes => 9999 * $GB );
    ok scalar @reasons >= 3, 'and one that does not is told why, by the shared arithmetic';
};

subtest 'a guest is a server with the domain for a name' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new(
        servers => [
            { id => 'a', name => 'vm.example.com',    status => 'ACTIVE' },
            { id => 'b', name => 'other.example.com', status => 'SHUTOFF' },
            { id => 'c', name => 'build.example.com', status => 'BUILD' },
        ]
    );

    is $hv->server('vm.example.com')->{id}, 'a',   'found by name';
    is $hv->server('nope.example.com'),     undef, 'and nothing when there is no such guest';

    ok $hv->domain_exists('vm.example.com'),    'exists';
    ok !$hv->domain_exists('nope.example.com'), 'does not';

    ok $hv->domain_is_running('vm.example.com'),     'ACTIVE is running';
    ok !$hv->domain_is_running('other.example.com'), 'SHUTOFF is not';
    ok !$hv->domain_is_running('build.example.com'), 'and neither is BUILD -- it exists without being usable';
    ok !$hv->domain_is_running('nope.example.com'),  'nor is a guest that is not there';

    like exception { $hv->server('') }, qr/needs a name/, 'and it wants a name to look for';
};

subtest 'two guests with one name is a thing to be told about' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new(
        servers => [
            { id => 'a', name => 'vm.example.com', status => 'ACTIVE' },
            { id => 'b', name => 'vm.example.com', status => 'ERROR' },
        ]
    );

    like exception { $hv->server('vm.example.com') }, qr/refusing to guess/,
      'because picking one of them would be picking which guest to destroy';
};

subtest 'the address we can actually reach' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new(
        networks => [
            { name => 'internal', 'router:external' => 0 },
            { name => 'public',   'router:external' => 1 },
        ],
        servers => [
            {
                id        => 'a',
                name      => 'vm.example.com',
                status    => 'ACTIVE',
                addresses => {
                    internal => [
                        { addr => '10.0.0.5',     'OS-EXT-IPS:type' => 'fixed' },
                        { addr => '203.0.113.10', 'OS-EXT-IPS:type' => 'floating' },
                    ],
                },
            },
            {
                id        => 'b',
                name      => 'nofloat.example.com',
                status    => 'ACTIVE',
                addresses => { internal => [ { addr => '10.0.0.6', 'OS-EXT-IPS:type' => 'fixed' } ] },
            },
            {
                id        => 'c',
                name      => 'direct.example.com',
                status    => 'ACTIVE',
                addresses => {
                    public => [
                        { addr => '2620:0:28a4::1', 'OS-EXT-IPS:type' => 'fixed' },
                        { addr => '10.2.65.133',    'OS-EXT-IPS:type' => 'fixed' },
                    ],
                },
            },
        ]
    );

    is $hv->guest_ssh_ip( undef, 'vm.example.com' ), '203.0.113.10',
      'the floating IP, not the fixed one -- a tenant address only routes inside the tenant';

    # The arrangement the cloud this was written against actually uses: no
    # tenant network at all, so the only address is on the external network and
    # Nova calls it 'fixed'.  Rejecting that rejects a guest that answers fine.
    is $hv->guest_ssh_ip( undef, 'direct.example.com' ), '10.2.65.133',
      'a fixed address on an external network is reachable, and is used';

    my $err = exception { $hv->guest_ssh_ip( undef, 'nofloat.example.com' ) };
    like $err, qr/no address we can reach/,  'a guest with only a tenant address is an error';
    like $err, qr/internal \(10\.0\.0\.6\)/, 'and it says what the guest is on';
    like $err, qr/floating_network/,         'and what to configure';

    like exception { $hv->guest_ssh_ip( undef, 'gone.example.com' ) }, qr/no guest called/,
      'as is one that is not there';
};

subtest 'the server list is a summary, so status comes from the detail' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new( servers => [ { id => 'a', name => 'vm.example.com', status => 'ACTIVE' } ] );

    # Nova's list carries no status.  Asking it would make every guest look
    # stopped, which is what this did until a real cloud was asked.
    ok $hv->domain_is_running('vm.example.com'),  'a running guest is seen to be running';
    ok scalar $FAKE->calls_to('server_from_uid'), 'because the detail was fetched';

    ok $hv->domain_exists('vm.example.com'), 'while existence needs only the list';
};

subtest 'snapshots live in glance, so the guest is in the name' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new(
        servers => [ { id => 'a', name => 'vm.example.com', status => 'ACTIVE' } ],
        images  => [
            { id => 'i1', name => 'vm.example.com@before',  created_at => '2026-01-01T00:00:00Z' },
            { id => 'i2', name => 'vm.example.com@after',   created_at => '2026-02-01T00:00:00Z' },
            { id => 'i3', name => 'other.example.com@nope', created_at => '2026-03-01T00:00:00Z' },
            { id => 'i4', name => 'ubuntu-24.04',           created_at => '2025-01-01T00:00:00Z' },
        ],
    );

    is_deeply [ $hv->snapshot_names('vm.example.com') ], [ 'after', 'before' ],
      'this guest\'s snapshots, newest first, and not another guest\'s or a base image';

    my ($listed) = $FAKE->calls_to('list_images');
    is $listed->[1]{image_type}, 'snapshot',
      'the listing is filtered at Glance, so the project\'s base images are not walked over here';

    is $hv->snapshot_current_name('vm.example.com'), 'after',
      'the newest stands in for libvirt\'s notion of the current one';

    $hv->create_snapshot( 'vm.example.com', 'now' );
    my ($created) = $FAKE->calls_to('create_image');
    is $created->[1], 'a',                  'snapshotting acts on the server';
    is $created->[3], 'vm.example.com@now', 'under a name that says which guest it belongs to';

    $hv->revert_snapshot( 'vm.example.com', 'before' );
    my ($action) = $FAKE->calls_to('server_action');
    is $action->[2]{rebuild}{imageRef}, 'i1',
      'reverting rebuilds onto that image, which keeps the server and its floating IP';

    like exception { $hv->revert_snapshot( 'vm.example.com', 'never' ) }, qr/no snapshot called 'never'/,
      'and a snapshot that does not exist says so';
};

subtest 'building a guest' => sub {
    my $hv = cloud(
        flavor           => 'm1.medium',
        image            => 'ubuntu-24.04',
        network          => 'internal',
        floating_network => 'public',
        keypair          => 'buildkey',
    );
    $FAKE = Test::FakeCloud->new();

    my $server = $hv->create_guest( name => 'vm.example.com', user_data => "#cloud-config\n" );

    is $server->{floating_ip_address}, '203.0.113.9', 'we get back something with an address on it';

    my ($call) = $FAKE->calls_to('create_vm');
    my $sent = $call->[1];

    is $sent->{name},                    'vm.example.com',   'the name';
    is $sent->{flavor},                  'm1.medium',        'the configured flavor';
    is $sent->{image},                   'ubuntu-24.04',     'and image';
    is $sent->{network},                 'internal',         'and network';
    is $sent->{network_for_floating_ip}, 'public',           'and where the floating IP comes from';
    is $sent->{key_name},                'buildkey',         'and the keypair';
    is $sent->{user_data},               "#cloud-config\n",  'the cloud-init payload goes to Nova, not to an ISO';
    is $sent->{metadata}{managed_by},    'trog-provisioner', 'and the guest is stamped as ours';
    is $sent->{metadata}{domain},        'vm.example.com',   'with the domain it is';

    is $hv->create_guest( name => 'x', flavor => 'other' )->{name}, 'x', 'a per-guest override works';

    like exception { $hv->create_guest() }, qr/needs a name/, 'a guest needs a name';
};

subtest 'building a guest the configuration cannot describe' => sub {
    my $hv = cloud( flavor => 'm1.medium' );
    $FAKE = Test::FakeCloud->new();

    my $err = exception { $hv->create_guest( name => 'vm.example.com' ) };
    like $err, qr/needs 'image'/,     'says which one is missing';
    like $err, qr/hypervisors\.conf/, 'and where to put it';
    is scalar $FAKE->calls_to('create_vm'), 0, 'and nothing was built';
};

subtest 'tearing down takes the billable things with it' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new(
        servers => [ { id => 'a', name => 'vm.example.com', status => 'ACTIVE' } ],
        volumes => [
            { id => 'v1', name => 'vm.example.com-data' },
            { id => 'v2', name => 'vm.example.com-logs' },
            { id => 'v3', name => 'somebody-elses-disk' },
            { id => 'v4', name => 'vm.example.com.backup' },
        ],
    );

    ok $hv->annihilate_domain('vm.example.com'), 'the guest goes';

    my ($deleted) = $FAKE->calls_to('delete_server');
    is $deleted->[1], 'a', 'by id';

    my @volumes = map { $_->[1] } $FAKE->calls_to('delete_volume');
    is_deeply [ sort @volumes ], [ 'v1', 'v2' ],
      'along with the volumes this tool named for it, and nothing else';

    # v4 is the interesting one: it starts with the domain name but is not
    # $domain-$purpose, so it is not ours and guessing would destroy data.
    ok !grep( { $_ eq 'v4' } @volumes ), 'a volume merely named similarly is left alone';
    ok !grep( { $_ eq 'v3' } @volumes ), 'and so is somebody else\'s';

    is $hv->annihilate_domain('vm.example.com'), 0,
      'and doing it again is not an error, because it is already gone';
};

subtest 'volumes and the console' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new( servers => [ { id => 'a', name => 'vm.example.com', status => 'ACTIVE' } ] );

    my $vol = $hv->create_volume( 'vm.example.com', 'data', size_gb => 40 );
    my ($made) = $FAKE->calls_to('create_volume');
    is $made->[1]{size}, 40,                    'a volume of the size asked for';
    is $made->[1]{name}, 'vm.example.com-data', 'named so that teardown will recognise it';

    $hv->attach_volume( 'vm.example.com', 'v9' );
    my ($attached) = $FAKE->calls_to('attach_volume');
    is $attached->[1], 'a',  'attaching goes through the server';
    is $attached->[2], 'v9', 'for that volume';

    like exception { $hv->create_volume( 'vm.example.com', 'data' ) }, qr/needs a size_gb/,
      'a volume needs a size';

    is $hv->console_log('vm.example.com'), "it booted\n",
      'and the console is readable, which is all there is when a guest never comes up';
};

subtest 'nothing to prepare, release or clear up after' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new;

    is $hv->prepare_host('/nonexistent/virtiofs-better'), 1, 'no host to prepare';
    is $hv->release_seed('vm.example.com'),               1, 'no drive to eject the seed from';
    is_deeply [ $hv->guest_volumes('vm.example.com') ], [], 'and no volumes left once the server has gone';
    is_deeply $FAKE->{calls},                           [], 'none of which asked the cloud anything';
};

subtest 'what it refuses to pretend to' => sub {
    my $hv = cloud();

    # Each of these is a libvirt noun.  Answering undef would let the caller
    # carry the wrong answer somewhere else before failing.
    my %because = (
        define_domain      => qr/not defined from libvirt XML/,
        cloudinit_iso      => qr/no ISO to build/,
        eject_cdrom        => qr/no cdrom/,
        pool_path          => qr/no storage pool/,
        pool_target        => qr/no storage pool/,
        nuke_pool          => qr/no storage pool/,
        base_image         => qr/Glance image/,
        create_disk        => qr/Cinder volume/,
        lease_ip           => qr/no lease table/,
        release_dhcp_lease => qr/no lease to release/,
        guest_mac          => qr/Neutron assigns the MAC/,
        nic_slots          => qr/no PCI topology/,
        nic_names          => qr/Neutron and cloud-init/,
        has_tpm            => qr/property of the flavor or image/,
    );

    # authorized_keys and hv_user used to be in this table.  They are
    # Trog::Machine's now, asked of Trog::Local rather than of a hypervisor, so
    # refusing them here would break an inherited method that works.
    ok Trog::HV::OpenStack->can('authorized_keys'), 'the machine methods are inherited, not refused';

    foreach my $method ( sort keys %because ) {
        my $err = exception { $hv->$method('vm.example.com') };
        like $err, qr/\QTrog::HV::OpenStack has no $method\E/, "$method says which call was made";
        like $err, $because{$method},                          "...and why there is no such thing here";
    }
};

done_testing();
