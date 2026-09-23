#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/hv-openstack.t - Trog::HV::OpenStack: what a cloud answers, and what it
refuses to pretend to

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp();
use Config::Simple();
use MIME::Base64();
use List::Util();

## no critic (CompileTime) -- it has to be set before anything reads it.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use FindBin::libs;

use Trog::HV();
use Trog::HV::OpenStack();

# What image_for_distro asks of a distro recipe, and nothing else.
{

    package Test::Distro;
    sub new             ( $class, $distribution, $version ) { return bless { distribution => $distribution, version => $version }, $class }
    sub distribution    ($self)                             { return $self->{distribution} }
    sub release_version ($self)                             { return $self->{version} }
}

# These patterns quotemeta a literal on purpose: a fixture string this test
# wrote itself, full of dots and slashes that would otherwise need escaping one
# at a time.  The policy is about production code, where a \Q...\E round
# anything but an interpolated value is usually an accident.
## no critic (RegularExpressions::PreventUselessMetacharacterEscapes)

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

    sub limits        ($self) { return $self->{limits} }
    sub volume_limits ($self) { return $self->{volume_limits} }

    sub list_images {
        my ( $self, %query ) = @_;
        $self->_record( list_images => \%query );

        # Glance filters on the os_ properties image_for_distro asks by.
        my @os = grep { m/\Aos_/ } keys %query;
        return grep {
            my $image = $_;
            List::Util::all { ( $image->{$_} // q{} ) eq $query{$_} } @os
        } @{ $self->{images} };
    }

    sub image_from_name {
        my ( $self, $name ) = @_;
        my @hit = grep { ( $_->{name} // '' ) eq $name } @{ $self->{images} };
        return $hit[0];
    }
    sub volumes ($self) { return @{ $self->{volumes} } }

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

    sub networks ($self) { return @{ $self->{networks} // [] } }

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

    sub delete_volume { my ( $s, $id ) = @_; $s->_record( delete_volume => $id ); return 1 }
    sub create_volume { my ( $s, %o )  = @_; $s->_record( create_volume => \%o ); return { id => 'vol-new', %o } }
    sub create_image  { my ( $s, @a )  = @_; $s->_record( create_image  => @a );  return 1 }
    sub server_action { my ( $s, @a )  = @_; $s->_record( server_action => @a );  return 1 }
}

my $FAKE;
my $mock = Test::MockModule->new('Trog::HV::OpenStack');
$mock->redefine( api => sub { return $FAKE } );

# guest_ssh_ip takes the guest from the configuration now, the way bin/provision
# hands it over -- its second argument is libvirt's lease and means nothing here.
sub conf_for {
    my ($name) = @_;

    my $conf = Config::Simple->new( syntax => 'simple' );
    $conf->param( 'domain', $name );

    return $conf;
}

sub cloud {
    my (%opts) = @_;
    Trog::HV->forget();
    return Trog::HV->candidate( cloud => 'testcloud', %opts );
}

subtest 'a cloud has to be named' => sub {
    like exception { Trog::HV::OpenStack->build() }, qr/needs[ ]a[ ]'cloud'/,
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
        network          => 'internal',
        floating_network => 'public',
        keypair          => 'buildkey',
    );

    is $hv->flavor,           'm1.medium', 'flavor';
    is $hv->network,          'internal',  'network';
    is $hv->floating_network, 'public',    'floating_network';
    is $hv->keypair,          'buildkey',  'keypair';
    is $hv->security_group,   'default',   'the security group defaults to the one every project has';

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

    like exception { $hv->server('') }, qr/needs[ ]a[ ]name/, 'and it wants a name to look for';
};

subtest 'two guests with one name is a thing to be told about' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new(
        servers => [
            { id => 'a', name => 'vm.example.com', status => 'ACTIVE' },
            { id => 'b', name => 'vm.example.com', status => 'ERROR' },
        ]
    );

    like exception { $hv->server('vm.example.com') }, qr/refusing[ ]to[ ]guess/,
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

    is $hv->guest_ssh_ip( conf_for('vm.example.com') ), '203.0.113.10',
      'the floating IP, not the fixed one -- a tenant address only routes inside the tenant';

    # The arrangement the cloud this was written against actually uses: no
    # tenant network at all, so the only address is on the external network and
    # Nova calls it 'fixed'.  Rejecting that rejects a guest that answers fine.
    is $hv->guest_ssh_ip( conf_for('direct.example.com') ), '10.2.65.133',
      'a fixed address on an external network is reachable, and is used';

    my $err = exception { $hv->guest_ssh_ip( conf_for('nofloat.example.com') ) };
    like $err, qr/no[ ]address[ ]we[ ]can[ ]reach/, 'a guest with only a tenant address is an error';
    like $err, qr/internal[ ]\(10\.0\.0\.6\)/,      'and it says what the guest is on';
    like $err, qr/floating_network/,                'and what to configure';

    like exception { $hv->guest_ssh_ip( conf_for('gone.example.com') ) }, qr/no[ ]guest[ ]called/,
      'as is one that is not there';
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

    like exception { $hv->revert_snapshot( 'vm.example.com', 'never' ) }, qr/no[ ]snapshot[ ]called[ ]'never'/,
      'and a snapshot that does not exist says so';
};

subtest 'a rollback is possible wherever there is a server to snapshot' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new( servers => [ { id => 'a', name => 'vm.example.com', status => 'ACTIVE' } ] );

    # A Glance image is not inside the server the way a libvirt snapshot is
    # inside the disk it was taken of, so a rebuild cannot take the snapshot
    # away with it.  That leaves one question: is there a guest to snapshot.
    ok $hv->rollback_possible('vm.example.com'),    'a guest that is there can be put back afterwards';
    ok !$hv->rollback_possible('nope.example.com'), 'and one that is not, cannot';

    # capacity is the libvirt backend's question, where the snapshot lives in
    # the disk and a disk of another size is a different file.  Here the root
    # disk is replaced from the image on every rebuild whatever its size.
    ok $hv->rollback_possible( 'vm.example.com', capacity => 1 ), 'the size being asked for changes nothing';
};

subtest 'a cloud rebuild never takes the guest apart' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new( servers => [ { id => 'a', name => 'vm.example.com', status => 'ACTIVE' } ] );

    # Nova replaces the root disk and keeps the server, its addresses and its
    # floating IP, so a rebuild has nothing to destroy and nothing to ask about.
    ok !$hv->rebuild_destroys_guest( 'vm.example.com', capacity => 42949672960 ),
      'a server that is there is rebuilt in place rather than taken apart';
    ok !$hv->rebuild_destroys_guest( 'nope.example.com', capacity => 42949672960 ),
      'and one that is not there has nothing to lose either';
};

subtest 'a cloud takes its rollback point without stopping the guest' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new( servers => [ { id => 'a', name => 'vm.example.com', status => 'ACTIVE' } ] );

    my $name = $hv->snapshot_before_rebuild('vm.example.com');

    like $name, qr/\A before-reprovision- \d{4}-\d{2}-\d{2}-\d{6} \z/,
      'named the way every backend names one, since an operator types it at bin/restore';

    my ($created) = $FAKE->calls_to('create_image');
    is $created->[3], "vm.example.com\@$name", 'and Glance holds it under the guest it was taken of';

    # Which is why disk_only is the backend's to interpret rather than the
    # caller's.  Nova images a server while it runs and writes no memory either
    # way, so stopping one here would make nothing possible and cost the guest
    # its uptime.
    is_deeply [ $FAKE->calls_to('server_action') ], [],
      'the server is never acted on, so it is still up when the rebuild reaches it';

    $FAKE = Test::FakeCloud->new;
    is $hv->snapshot_before_rebuild('nope.example.com'), undef,
      'and a guest that is not there has nothing to go back to';
};

subtest 'image_for_distro' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new(
        images => [
            { id => 'old',    os_distro => 'ubuntu', os_version => '24.04', status => 'active', created_at => '2026-01-01T00:00:00Z' },
            { id => 'new',    os_distro => 'ubuntu', os_version => '24.04', status => 'active', created_at => '2026-06-01T00:00:00Z' },
            { id => 'queued', os_distro => 'ubuntu', os_version => '24.04', status => 'queued', created_at => '2026-07-01T00:00:00Z' },
            { id => 'snap',   os_distro => 'ubuntu', os_version => '24.04', status => 'active', created_at => '2026-08-01T00:00:00Z', image_type => 'snapshot' },
            { id => 'jammy',  os_distro => 'ubuntu', os_version => '22.04', status => 'active', created_at => '2026-09-01T00:00:00Z' },
        ]
    );

    is $hv->image_for_distro( Test::Distro->new( ubuntu => '24.04' ) ), 'new', 'the newest active image of that distribution and version, and never a snapshot of one';

    my $err = exception { $hv->image_for_distro( Test::Distro->new( debian => '12' ) ) };
    like $err, qr/os_distro=debian[ ]and[ ]os_version=12/, 'one the cloud has none of is said';
    like $err, qr/openstack[ ]image[ ]set[ ]--property/,   'with how to mark one';
};

subtest 'building a guest' => sub {
    my $hv = cloud(
        flavor           => 'm1.medium',
        network          => 'internal',
        floating_network => 'public',
        keypair          => 'buildkey',
    );
    $FAKE = Test::FakeCloud->new();

    my $server = $hv->create_guest( name => 'vm.example.com', image => 'ubuntu-24.04', user_data => "#cloud-config\n" );

    is $server->{floating_ip_address}, '203.0.113.9', 'we get back something with an address on it';

    my ($call) = $FAKE->calls_to('create_vm');
    my $sent = $call->[1];

    is $sent->{name},                    'vm.example.com',   'the name';
    is $sent->{flavor},                  'm1.medium',        'the configured flavor';
    is $sent->{image},                   'ubuntu-24.04',     'and the image it was given';
    is $sent->{network},                 'internal',         'and network';
    is $sent->{network_for_floating_ip}, 'public',           'and where the floating IP comes from';
    is $sent->{key_name},                'buildkey',         'and the keypair';
    is $sent->{user_data},               "#cloud-config\n",  'the cloud-init payload goes to Nova, not to an ISO';
    is $sent->{metadata}{managed_by},    'trog-provisioner', 'and the guest is stamped as ours';
    is $sent->{metadata}{domain},        'vm.example.com',   'with the domain it is';

    is $hv->create_guest( name => 'x', image => 'ubuntu-24.04', flavor => 'other' )->{name}, 'x', 'a per-guest override works';

    like exception { $hv->create_guest() }, qr/needs[ ]a[ ]name/, 'a guest needs a name';
};

subtest 'building a guest the configuration cannot describe' => sub {
    my $hv = cloud( flavor => 'm1.medium' );
    $FAKE = Test::FakeCloud->new();

    my $err = exception { $hv->create_guest( name => 'vm.example.com' ) };
    like $err, qr/needs[ ]an[ ]image/,              'says which one is missing';
    like $err, qr/the[ ]distro[ ]recipe[ ]decides/, 'and what decides it';

    $err = exception { $hv->create_guest( name => 'vm.example.com', image => 'ubuntu-24.04' ) };
    like $err, qr/needs[ ]'network'/, 'says which of the block\'s is missing';
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

subtest 'volumes' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new( servers => [ { id => 'a', name => 'vm.example.com', status => 'ACTIVE' } ] );

    $hv->create_volume( 'vm.example.com', 'data', size_gb => 40 );
    my ($made) = $FAKE->calls_to('create_volume');
    is $made->[1]{size}, 40,                    'a volume of the size asked for';
    is $made->[1]{name}, 'vm.example.com-data', 'named so that teardown will recognize it';

    like exception { $hv->create_volume( 'vm.example.com', 'data' ) }, qr/needs[ ]a[ ]size_gb/,
      'a volume needs a size';
};

subtest 'a guest that is there already is rebuilt, not replaced' => sub {
    my @asked;
    $mock->redefine( _nova => sub { my ( $self, @args ) = @_; push @asked, \@args; return {} } );

    my $hv = cloud();
    $FAKE = Test::FakeCloud->new(
        servers => [ { id => 's1',    name => 'vm.example.com', status => 'ACTIVE' } ],
        images  => [ { id => 'img-1', name => 'noble' } ],
    );

    my $server = $hv->rebuild_guest( 'vm.example.com', image => 'noble', user_data => "#cloud-config\n" );

    is_deeply $asked[0],
      [ POST => '/servers/s1/action', { rebuild => { imageRef => 'img-1', user_data => MIME::Base64::encode_base64( "#cloud-config\n", '' ) } }, '2.57' ],
      'a rebuild onto the image, with the new payload, at the microversion that takes it';
    is $server->{id},                           's1', 'the same server comes back';
    is scalar $FAKE->calls_to('delete_server'), 0,    'and nothing was deleted to get there';

    @asked = ();
    $hv->rebuild_guest( 'vm.example.com', image => '0b8f6a4e-1c2d-4e5f-8a9b-0c1d2e3f4a5b' );
    is $asked[0][2]{rebuild}{imageRef}, '0b8f6a4e-1c2d-4e5f-8a9b-0c1d2e3f4a5b', 'an image named by id is used as it is';

    like exception { $hv->rebuild_guest( 'vm.example.com', image => 'nosuch' ) }, qr/no[ ]image[ ]called[ ]'nosuch'/,
      'an image that is not there is said, not sent';
    like exception { $hv->rebuild_guest('gone.example.com') }, qr/no[ ]guest[ ]called[ ]'gone\Nexample\Ncom'/,
      'and so is a guest that is not';

    # ERROR does not change on its own, so it is not something to wait out.
    $FAKE->{servers}[0]{status} = 'ERROR';
    $FAKE->{servers}[0]{fault}  = { message => 'No valid host was found' };
    like exception { $hv->rebuild_guest( 'vm.example.com', image => 'noble' ) }, qr/left[ ]it[ ]in[ ]ERROR:[ ]No[ ]valid[ ]host[ ]was[ ]found/,
      'a rebuild that failed says so at once, with what Nova said';

    $mock->unmock('_nova');
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
        define_domain      => qr/not[ ]defined[ ]from[ ]libvirt[ ]XML/,
        cloudinit_iso      => qr/no[ ]ISO[ ]to[ ]build/,
        eject_cdrom        => qr/no[ ]cdrom/,
        pool_path          => qr/no[ ]storage[ ]pool/,
        pool_target        => qr/no[ ]storage[ ]pool/,
        base_image         => qr/Glance[ ]image/,
        create_disk        => qr/Cinder[ ]volume/,
        lease_ip           => qr/no[ ]lease[ ]table/,
        release_dhcp_lease => qr/no[ ]lease[ ]to[ ]release/,
        guest_mac          => qr/Neutron[ ]assigns[ ]the[ ]MAC/,
        nic_slots          => qr/no[ ]PCI[ ]topology/,
        nic_names          => qr/Neutron[ ]and[ ]cloud-init/,
        has_tpm            => qr/property[ ]of[ ]the[ ]flavor[ ]or[ ]image/,
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

subtest 'what bin/debug_boot can ask a cloud for' => sub {
    my $hv = cloud();
    $FAKE = Test::FakeCloud->new( servers => [ { id => 's1', name => 'vm.example.com', status => 'ACTIVE' } ] );

    is_deeply [ sort $hv->debug_actions ], [qw{console fetch vnc}], 'the three Nova answers, and not the ones that need a disk or a domain';
    is $hv->console_capture( 'vm.example.com', wait => 45 ), 0, 'nothing is restarted to read a console the cloud already keeps';

    my @asked;
    $mock->redefine( _nova => sub { my ( $self, @args ) = @_; push @asked, \@args; return { output => "[    0.000000] Linux version 6.8.0\n" } } );

    is $hv->console_output('vm.example.com'), "[    0.000000] Linux version 6.8.0\n", 'the console log comes back as text';
    is_deeply $asked[0], [ POST => '/servers/s1/action', { 'os-getConsoleOutput' => { length => 5000 } } ],
      'asked of the server, for enough lines to hold a boot';

    $mock->redefine( _nova => sub { return {} } );
    is $hv->console_output('vm.example.com'), undef, 'a server with no console output says none rather than an empty file';

    @asked = ();
    $mock->redefine( _nova => sub { my ( $self, @args ) = @_; push @asked, \@args; return { remote_console => { type => 'novnc', url => 'https://cloud.test/vnc_auto.html?token=abc' } } } );

    my ( $advice, $url ) = $hv->vnc_access('vm.example.com');
    is $url, 'https://cloud.test/vnc_auto.html?token=abc', 'the console URL is the thing to act on';
    like $advice, qr/Open[ ]this[ ]in[ ]a[ ]browser/, 'and the advice says what to do with it';
    like $advice, qr/expires[ ]the[ ]token/,          'and that it does not keep';
    is_deeply $asked[0], [ POST => '/servers/s1/remote-consoles', { remote_console => { protocol => 'vnc', type => 'novnc' } }, '2.6' ],
      'asked through remote-consoles, at the microversion that has it';

    $mock->redefine( _nova => sub { return {} } );
    like exception { $hv->vnc_access('vm.example.com') }, qr/no[ ]display[ ]to[ ]connect[ ]to/, 'a server the cloud gives no URL for says so';

    like exception { $hv->console_output('gone.example.com') }, qr/no[ ]guest[ ]called[ ]'gone\Nexample\Ncom'/, 'and a server that is not there is named';

    $mock->unmock('_nova');
};

done_testing();
