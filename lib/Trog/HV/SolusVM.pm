package Trog::HV::SolusVM;

#ABSTRACT: the SolusVM backend: a management node's servers, plans and snapshots.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';
use parent 'Trog::HV';

use List::Util qw{first};
use SolusVM::Client();

use Trog::Secrets();

=head1 NAME

Trog::HV::SolusVM - the SolusVM backend: a management node's servers, plans and
snapshots

=head1 SYNOPSIS

    # Not built directly.  A hypervisors.conf block naming a node gets you one.
    my $hv = Trog::HV->new(solusvm => 'solus.example.test', plan => 'c2.d40.r2048');

    $hv->create_guest(name => 'vm.example.test', user_data => $cloud_config);
    print $hv->guest_ssh_ip($config), "\n";
    $hv->annihilate_domain('vm.example.test');

=head1 DESCRIPTION

A SolusVM management node we ask for guests, rather than a machine we build them
on ourselves.  It is the same shape of thing as L<Trog::HV::OpenStack> -- an API
that owns the hypervisors, not a hypervisor we have a shell on -- and it differs
from that one in the places worth knowing about:

=over 4

=item * A guest has a B<plan>, which is SolusVM's word for what Nova calls a
flavor: cores, memory and disk together, priced.  What plans exist is the node's
to say.

=item * It is installed from an B<OS image version>, not an image.  C<Debian> is
an image; C<Debian 13> is the version, and the version is what has an id.

=item * A guest belongs to a B<project>, and for most accounts the project is
where the API answers at all.  See L</Two of nearly everything> below.

=item * B<Placement is the node's job.>  It has compute resources and locations
and it decides which one a plan lands on.  We name a location; we do not choose
a host.

=item * There is no B<floating IP>.  A server comes up with the addresses its
location's IP blocks give it, and the primary one is the address.

=back

=head2 Two of nearly everything

Half the SolusVM API exists twice: C</servers> and C</plans> are the whole node,
and C</projects/{id}/servers> and C</projects/{id}/plans> are one project's view
of it.  Which pair answers depends on the token: an account with the C<CLIENT>
role gets C<403 This action is unauthorized> from the node-wide half and its own
resources from the project half.

This backend uses the project half throughout.  A token that can administer the
node can also see its own project, so the project half works for either kind of
account, and the node-wide half works only for one.

=head1 CLASS METHODS

=cut

my $MB = 1024 * 1024;
my $GB = 1024 * 1024 * 1024;

# How long to wait for a server to finish being built or reinstalled, and for a
# deleted one to actually go.
our $BUILD_TIMEOUT  = 900;
our $DELETE_TIMEOUT = 300;

# How often to ask again while waiting.  A build took about thirty seconds on
# the node this was written against, so this is a handful of requests, not a
# spin.
our $POLL_SECONDS = 5;

=head2 config_keys

The F<hypervisors.conf> keys this backend reads.  C<solusvm> is what marks a
block as one of ours: it names the management node's hostname.

Everything else is prefixed, because C<plan> and C<location> are words another
backend could want and a F<provision.conf> is read by all of them at once.

=cut

sub config_keys {
    return (
        solusvm => 'solusvm',
        ( map { $_ => "solusvm_$_" } qw{token project plan location os} ),
        domain_dir => 'domain_dir',
    );
}

=head2 build(%opts)

Build one.  C<solusvm> is required: it is the node this talks to, and there is
no default worth guessing.

Nothing is contacted here, and the secret store is not opened.  Both happen when
something first asks a question that needs them, so that building the object --
which C<bin/new_config> does merely to read a path off it -- costs neither a
round trip nor a password prompt.

=cut

sub build {
    my ( $class, %given ) = @_;

    die "A SolusVM hypervisor needs a 'solusvm' naming the management node\n"
      unless defined $given{solusvm} && length $given{solusvm};

    return bless {%given}, $class;
}

=head1 IDENTITY

=head2 is_local

True, for the same reason it is true of a cloud: there is no hypervisor
filesystem to reach, so every file operation L<Trog::Machine> offers is a local
one.

=head2 builds_by_api, manages_addresses

Both true.  A guest is asked for rather than defined, and the node gives it the
address it comes up at.

=head2 host, describe, uri

=cut

sub is_local          { return 1 }
sub builds_by_api     { return 1 }
sub manages_addresses { return 1 }

sub host     { return $_[0]->{solusvm} }
sub describe { return 'the SolusVM node ' . $_[0]->{solusvm} }
sub uri      { return 'https://' . $_[0]->{solusvm} . '/api/v1' }

=head2 plan, location, os

What F<hypervisors.conf> said to build guests with.  A plan and a location may
each be a name or an id; C<os> is an OS image version id, because a version is
what gets installed and what the API takes.

=cut

sub plan     { return $_[0]->{plan} }
sub location { return $_[0]->{location} }
sub os       { return $_[0]->{os} }

=head1 THE API

=head2 api

The L<SolusVM::Client> this talks to, and the only place the token is read.

Built on first use, so an object nobody asks a question of never opens the
store.

=cut

sub api {
    my ($self) = @_;
    return $self->{_api} if $self->{_api};

    return $self->{_api} = SolusVM::Client->new(
        host  => $self->host,
        token => $self->token,
    );
}

=head2 token

The API token, resolved out of F<secrets.kdbx> if that is where it is.

A SolusVM token is a bearer token with no expiry, so a node signed into through
an identity provider -- which is every node with Active Directory in front of it
-- has no password to offer instead.  That makes the token the whole credential,
which is exactly the kind of thing that should not be sitting in a file in the
clear:

    solusvm_token = secret:solusvm/qa/password

=cut

sub token {
    my ($self) = @_;

    my $token = $self->{token};
    die 'No token for ' . $self->describe . ".\n" . "Set solusvm_token in its block in hypervisors.conf, as a secret: reference.\n"
      unless defined $token && length $token;

    return $token unless index( $token, 'secret:' ) == 0;
    return $self->{_token} //= Trog::Secrets->reader($token)->();
}

=head2 project

The project guests are built in.

Named by F<hypervisors.conf> where there is a choice.  Where the account has
exactly one, that is the one, because making somebody write down the only
possible answer is how a configuration file grows keys nobody understands.

=cut

sub project {
    my ($self) = @_;
    return $self->{project}  if defined $self->{project} && length $self->{project};
    return $self->{_project} if $self->{_project};

    my @projects = $self->_list('get_list_of_projects');

    die 'The account on ' . $self->describe . " has no projects, so there is nowhere to build.\n"
      unless @projects;

    die 'The account on ' . $self->describe . ' has ' . scalar(@projects) . " projects, so one has to be named.\n" . "Set solusvm_project in its block in hypervisors.conf to one of: " . join( ', ', map { "$_->{name} ($_->{id})" } @projects ) . "\n"
      if @projects > 1;

    return $self->{_project} = $projects[0]{id};
}

# Every page of a listing, with the single-page case costing one request.  The
# project's plans run to three pages on a node of any size, and a plan missed
# because it was on page two is a build that fails saying the plan does not
# exist.
sub _list {
    my ( $self, $operation, %params ) = @_;
    return grep { ref $_ } $self->api->paginate( $operation, %params );
}

=head1 CAPACITY

What a SolusVM account may have, which is not what a libvirt host has.

The node runs its own placement: a plan names cores, memory and disk, and which
compute resource in the location can take them is the node's decision and not
ours.  So there is no free-memory figure here that means what it means on a
machine, and inventing one would put this tool in the business of second
guessing a scheduler it cannot see.

What does constrain us is the account's limit on how many servers it may have,
and whether the plan we are configured to build is big enough for what the guest
asked for.  Those are the two things L</capacity> answers with.

=head2 cpu_overcommit

1, always, for the reason it is 1 on a cloud: a plan is already what you may
run, so multiplying it invents headroom the node will refuse to honour.

=cut

sub cpu_overcommit { return 1 }

=head2 reserve_memory, reserve_cpus, reserve_disk

Nothing, whatever F<hypervisors.conf> says.

A reserve is memory left for a host we are sharing.  We are not sharing this
node's hosts -- we cannot even see them -- and holding back a slice of a plan
that is sold whole would only refuse guests the node would have built.

=cut

sub reserve_memory { return 0 }
sub reserve_cpus   { return 0 }
sub reserve_disk   { return 0 }

=head2 max_guests

What F<hypervisors.conf> says, else the account's own server limit, else no cap.

=cut

sub max_guests {
    my ($self) = @_;
    return $self->{max_guests} if $self->{max_guests};
    return $self->capacity->{guests_allowed};
}

=head2 capacity

As L<Trog::HV/capacity>, with the size figures taken from the configured plan --
that being what a guest built here actually gets -- and the guest count taken
from the project.

C<memory_free> and the rest are therefore the size of one guest rather than the
size of a fleet.  Read the shape as L<Trog::HV/shortfalls(%needs)> reads it and
it says the true thing: a guest asking for more memory than the plan provides
does not fit, and one asking for less does.

Cached for the life of the object, as every backend's is.

=cut

sub capacity {
    my ($self) = @_;
    return $self->{capacity} if $self->{capacity};

    my $plan   = eval { $self->plan_detail } // {};
    my $params = $plan->{params}             // {};

    my $memory_mb   = int( ( $params->{ram} // 0 ) / $MB );
    my $cpus        = $params->{vcpu} // $params->{cores} // 0;
    my $disk        = ( $params->{disk} // 0 ) * $GB;
    my $limit_usage = $self->_account->{limit_usage} // {};

    return $self->{capacity} = {
        memory_mb        => $memory_mb,
        memory_committed => 0,
        memory_free      => $memory_mb,
        cpus             => $cpus,
        cpus_allocatable => $cpus,
        cpus_committed   => 0,
        cpus_free        => $cpus,
        disk_free        => $disk,
        guests           => scalar( $self->guest_names ),

        # Not part of the shape Trog::HV reads; max_guests wants it.  Null means
        # the account is in no limit group, which is the node saying it has no
        # opinion -- 0 is how this toolkit spells that.
        guests_allowed => $limit_usage->{servers} // 0,
    };
}

sub _account {
    my ($self) = @_;
    return $self->{_account} //= $self->api->get_user_info()->{data} // {};
}

=head2 roles

What the token's account may do, as the node names it.  C<CLIENT> is an account
that uses the node; anything else administers some part of it.

=cut

sub roles {
    my ($self) = @_;
    return map { $_->{name} // () } @{ $self->_account->{roles} // [] };
}

=head2 plan_detail

The configured plan, in full.  By id when F<hypervisors.conf> named a number, by
name otherwise, because a plan is called something like C<c8.d80.r1024 - Shared
LVM> and nobody wants that in two places.

=cut

sub plan_detail {
    my ($self) = @_;
    return $self->{_plan} if $self->{_plan};

    my $wanted = $self->plan;
    die 'Building on ' . $self->describe . " needs a plan.\n" . "Set solusvm_plan in its block in hypervisors.conf.\n"
      unless defined $wanted && length $wanted;

    my @plans = $self->_list( 'get_list_of_project_plans', id => $self->project );
    my $found = first { _is( $_, $wanted ) } @plans;

    die "There is no plan '$wanted' on " . $self->describe . ".\n" . 'The project has ' . scalar(@plans) . " to choose from; ask it with:\n" . "    perl -MSolusVM::Client -e '...->catalog( like => qr/plans/ )'\n"
      unless $found;

    return $self->{_plan} = $found;
}

=head2 location_id

The configured location's id, looked up by name where it was given as one.

=cut

sub location_id {
    my ($self) = @_;
    return $self->{_location} if $self->{_location};

    my $wanted = $self->location;
    die 'Building on ' . $self->describe . " needs a location.\n" . "Set solusvm_location in its block in hypervisors.conf.\n"
      unless defined $wanted && length $wanted;

    my @locations = $self->_list('get_list_of_locations');
    my $found     = first { _is( $_, $wanted ) } @locations;

    die "There is no location '$wanted' on " . $self->describe . ".\n" . 'It has: ' . join( ', ', map { "$_->{name} ($_->{id})" } @locations ) . "\n"
      unless $found;

    return $self->{_location} = $found->{id};
}

# Whether a thing the node listed is the one named, by id or by name.  Both,
# because hypervisors.conf may say either and a name is the readable one.
sub _is {
    my ( $thing, $wanted ) = @_;
    return 1 if defined $thing->{id}   && "$thing->{id}" eq "$wanted";
    return 1 if defined $thing->{name} && $thing->{name} eq $wanted;
    return 0;
}

=head1 GUESTS

A guest is a server whose name is the domain name, which is the identity libvirt
and Nova both use too.

=head2 servers

Every server in the project.

=head2 server($name)

The one called C<$name>, or nothing.

Dies where two servers share the name, rather than picking one: the next thing
this tool would do with the answer is rebuild it or delete it.

=cut

sub servers {
    my ($self) = @_;
    return $self->_list( 'get_list_of_project_servers', id => $self->project );
}

sub server {
    my ( $self, $name ) = @_;

    my @found = grep { ( $_->{name} // '' ) eq $name } $self->servers;

    die "There are " . scalar(@found) . " servers called '$name' on " . $self->describe . ".\n" . "Names are how this tool identifies a guest, so it will not guess which you meant.\n"
      if @found > 1;

    return $found[0];
}

=head2 server_detail($name)

The same, fetched by id so that the answer has everything on it.  A listing is
abbreviated; addresses in particular are not on it.

=cut

sub server_detail {
    my ( $self, $name ) = @_;

    my $server = $self->server($name) or return undef;
    return $self->api->get_an_existing_server( id => $server->{id} )->{data};
}

=head2 guest_names

Every server in the project, whatever built it.  Not only ours: an orphan sweep
asks "is anything still using this name", and one somebody else created is.

=head2 domain_exists($name)

=cut

sub guest_names {
    return map { $_->{name} // () } $_[0]->servers;
}
sub domain_exists { return defined $_[0]->server( $_[1] ) ? 1 : 0 }

=head2 guest_ssh_ip($config, $lease)

The address to reach a guest at: its primary IPv4.

C<$lease> is libvirt's NAT lease and means nothing here, and is taken and ignored
so that F<bin/provision> can ask either backend the same way.

=cut

sub guest_ssh_ip {
    my ( $self, $config, $_lease ) = @_;

    my $name = ref $config ? $config->param('domain') : $config;

    my $server = $self->server_detail($name)
      or die "There is no guest called '$name' on " . $self->describe . "\n";

    my @addresses = @{ $server->{ip_addresses}{ipv4} // [] };

    # is_primary is the node's own answer to "which of these is the address",
    # and it is the one its DNS and its panel show.
    my $primary = first { $_->{is_primary} } @addresses;
    return $primary->{ip} if $primary && length( $primary->{ip} // '' );

    return $addresses[0]{ip} if @addresses && length( $addresses[0]{ip} // '' );

    die "The guest '$name' has no IPv4 address to reach it at.\n" . "It is " . ( $server->{status} // 'in no state the node would name' ) . "; a server still being built has no address yet.\n";
}

=head1 SNAPSHOTS

SolusVM snapshots belong to the server, so unlike Glance images they need no
prefix to say whose they are.

=head2 snapshot_names($domain)

Newest first.

=head2 snapshot_current_name($domain)

The newest.  SolusVM tracks no "current" pointer, and the newest is what the
caller is after.

=cut

sub snapshot_names {
    my ( $self, $domain ) = @_;
    return map { $_->{name} // () } $self->_snapshots($domain);
}

sub snapshot_current_name {
    my ( $self, $domain ) = @_;
    my ($newest) = $self->snapshot_names($domain);
    return $newest;
}

sub _snapshots {
    my ( $self, $domain ) = @_;

    my $server = $self->server($domain)
      or die "There is no guest called '$domain' to ask about snapshots\n";

    return sort { ( $b->{created_at} // '' ) cmp ( $a->{created_at} // '' ) } $self->_list( 'get_list_of_server_snapshots', id => $server->{id} );
}

=head2 create_snapshot($domain, $name)

=head2 revert_snapshot($domain, $name)

Take one, and put the guest back on one.  Reverting is by the snapshot's own id,
which is why the snapshot has to be found first.

=cut

sub create_snapshot {
    my ( $self, $domain, $name ) = @_;

    my $server = $self->server($domain)
      or die "There is no guest called '$domain' to snapshot\n";

    $self->api->create_a_new_server_snapshot( id => $server->{id}, name => $name );
    return 1;
}

sub revert_snapshot {
    my ( $self, $domain, $name ) = @_;

    my $snapshot = first { ( $_->{name} // '' ) eq $name } $self->_snapshots($domain);

    die "The guest '$domain' has no snapshot called '$name'\n" unless $snapshot;

    $self->api->revert_snapshot( id => $snapshot->{id} );
    return 1;
}

=head1 BUILDING AND TEARING DOWN

=head2 create_guest(%spec)

Build a guest and wait for the node to call it started.

C<name> is required.  C<plan>, C<location> and C<os> default to what
F<hypervisors.conf> said, so a caller normally passes only the name and the
payload.  C<user_data> is the cloud-init payload, which the node hands the guest
itself -- there is no seed ISO here, exactly as there is none on a cloud.

Returns the server, in full.

=cut

sub create_guest {
    my ( $self, %spec ) = @_;

    my $name = $spec{name};
    die "create_guest needs a name\n" unless defined $name && length $name;

    my $os = $spec{os} // $self->os;
    die "Building '$name' on " . $self->describe . " needs an os image version.\n" . "Set solusvm_os in its block in hypervisors.conf -- a version's id, not an image's.\n"
      unless defined $os && length $os;

    my %optional;
    $optional{user_data} = $spec{user_data} if defined $spec{user_data} && length $spec{user_data};

    my $made = $self->api->create_a_new_project_server(
        id   => $self->project,
        name => $name,

        # The project endpoint's body is not the node-wide one's: plan_id rather
        # than plan, and so on.  They are different operations with different
        # schemas, and only one of them answers for a CLIENT.
        plan_id             => $spec{plan}     // $self->plan_detail->{id},
        location_id         => $spec{location} // $self->location_id,
        os_image_version_id => $os,
        %optional,
    );

    return $self->_wait_for_started( $made->{data}{id}, $name );
}

=head2 reinstall_guest($name, user_data => $seed)

Put the OS back on a guest that already exists, with a fresh cloud-init payload,
and wait for it to come back.

This is the counterpart of Nova's rebuild: the server survives, and so does its
address, which is the whole reason to prefer it over deleting and building
again.  The payload is the point -- it carries the key F<bin/provision> has just
generated, and a reinstall that kept the old one would bring the guest up locked
against us.

=cut

sub reinstall_guest {
    my ( $self, $name, %spec ) = @_;

    my $server = $self->server($name)
      or die "There is no guest called '$name' to reinstall\n";

    my $os = $spec{os} // $self->os;
    die "Reinstalling '$name' on " . $self->describe . " needs an os image version.\n" . "Set solusvm_os in its block in hypervisors.conf.\n"
      unless defined $os && length $os;

    my %optional;
    $optional{user_data} = $spec{user_data} if defined $spec{user_data} && length $spec{user_data};

    # 'os' here, not 'os_image_version_id'.  Reinstall and create are different
    # operations and the document gives them different names for the same thing;
    # catalog() in SolusVM::Client is where that is visible.
    $self->api->reinstall_server( id => $server->{id}, os => $os, %optional );

    return $self->_wait_for_started( $server->{id}, $name );
}

# Poll until the node has finished with the server.
#
# Waits for 'started' rather than watching for the states in between, because
# the states in between are not all documented: the API reference gives status
# five values, and a server part way through a reinstall reports a sixth,
# 'reinstalling', which was seen on a live one while this was being written.
# Treating anything that is not 'started' as "still working" is what makes that
# a non-event; only 'unavailable' is worth giving up on, because it is the one
# the node will not come out of by itself.
sub _wait_for_started {
    my ( $self, $id, $name, $timeout ) = @_;

    $timeout //= $BUILD_TIMEOUT;
    my $deadline = time + $timeout;

    while (1) {
        my $detail = $self->api->get_an_existing_server( id => $id )->{data} // {};
        my $status = $detail->{status}                                       // '';

        return $detail if $status eq 'started' && !$detail->{is_processing};

        die "Building '$name' left it unavailable, which it will not come out of on its own.\n"
          if $status eq 'unavailable';

        last if time >= $deadline;
        sleep $POLL_SECONDS;
    }

    die "The guest '$name' had not started ${timeout}s after being asked for.\n" . "Look at it in the panel: a task that failed stays failed.\n";
}

=head2 prepare_host

=head2 release_seed($domain)

=head2 guest_volumes($domain)

Nothing, each for its own reason, and the same reasons a cloud has.  There is no
machine to prepare, no seed drive to release -- the payload is a field on the
server -- and the disks a guest has go with it when it is deleted.

=cut

sub prepare_host  { return 1 }
sub release_seed  { return 1 }
sub guest_volumes { return () }

=head2 clear_guest($domain)

Nothing.

The libvirt path deletes the domain and its disks before making them again,
because that is what rebuilding amounts to there.  Here the guest is reinstalled
in place and keeps its address, so clearing anything first would throw away the
one thing worth keeping.

=cut

sub clear_guest { return 1 }

=head2 annihilate_domain($name)

Take the guest away.  Returns false when there was no such guest, which makes it
safe to call on a name that may already be gone.

=cut

sub annihilate_domain {
    my ( $self, $name ) = @_;

    my $server = $self->server($name);
    return 0 unless $server;

    $self->api->delete_server( id => $server->{id} );
    $self->_wait_for_gone($name);

    return 1;
}

# The node's delete is a task, not an act, so the server is still listed for a
# while after it is accepted.  The interesting failure -- the task failed and
# the server is staying -- looks exactly like slowness until the wait runs out.
sub _wait_for_gone {
    my ( $self, $name, $timeout ) = @_;

    $timeout //= $DELETE_TIMEOUT;
    my $deadline = time + $timeout;

    while ( time < $deadline ) {
        return 1 unless $self->server($name);
        sleep $POLL_SECONDS;
    }

    die "The guest '$name' was still there ${timeout}s after being deleted.\n" . "Look at the task in the panel: one that failed will not retry itself.\n";
}

=head1 WHAT THIS CANNOT DO

The libvirt nouns, which mean nothing here.  Each says so rather than returning
an undef the caller would carry somewhere else before failing.

=cut

sub _no_such_thing {
    my ( $self, $method, $why ) = @_;
    die $self->describe . " has no $method: $why.\n";
}

sub define_domain { return $_[0]->_no_such_thing( 'define_domain', 'a server is asked for, not defined from libvirt XML -- use create_guest' ) }
sub cloudinit_iso { return $_[0]->_no_such_thing( 'cloudinit_iso', 'the node takes cloud-init as user_data, so there is no ISO to build' ) }
sub eject_cdrom   { return $_[0]->_no_such_thing( 'eject_cdrom',   'there is no cdrom' ) }
sub pool_path     { return $_[0]->_no_such_thing( 'pool_path',     'there is no storage pool' ) }
sub pool_target   { return $_[0]->_no_such_thing( 'pool_target',   'there is no storage pool' ) }
sub nuke_pool     { return $_[0]->_no_such_thing( 'nuke_pool',     'there is no storage pool' ) }
sub base_image    { return $_[0]->_no_such_thing( 'base_image',    'a root disk comes from an OS image version the node holds, not a downloaded file' ) }
sub create_disk   { return $_[0]->_no_such_thing( 'create_disk',   'a disk is part of the plan, or an additional disk the node manages' ) }
sub lease_ip      { return $_[0]->_no_such_thing( 'lease_ip',      'the node assigns addresses out of its IP blocks; there is no lease table' ) }

sub release_dhcp_lease { return $_[0]->_no_such_thing( 'release_dhcp_lease', 'the node assigns addresses; there is no lease to release' ) }
sub guest_mac          { return $_[0]->_no_such_thing( 'guest_mac',          'the node assigns the MAC, so it cannot be derived from the name' ) }
sub nic_slots          { return $_[0]->_no_such_thing( 'nic_slots',          'there is no PCI topology to pin an interface to' ) }
sub nic_names          { return $_[0]->_no_such_thing( 'nic_names',          'interface names come from the node and cloud-init, not from a PCI slot' ) }
sub has_tpm            { return $_[0]->_no_such_thing( 'has_tpm',            'a TPM is a property of the plan, not of a host' ) }

=head1 PROVISIONING

=head2 @names = $hv->preflight_checks(), $hv->preflight_notes()

What C<bin/preflight> asks of this backend, in order.

=cut

sub preflight_checks { return qw{check_reachable check_solusvm_resources check_solusvm_quota check_rsync check_transfer_ip check_fetch_sources check_config} }
sub preflight_notes  { return qw{note_stale_image note_apt_mirror note_plaintext_secrets} }

# Whether the token works, and what it is allowed to do.  Everything below needs
# this to have worked.
sub check_reachable {
    my ($self) = @_;

    my $account = eval { $self->_account };
    return $self->_verdict( 0, 'Could not reach ' . $self->describe . ' with that token', <<"FIX" ) unless $account && $account->{email};
$@
A SolusVM token is made in the panel under Account, and does not expire -- so a
token that has stopped working has been revoked, or belongs to an account that
has.  A node fronted by an identity provider has no password to use instead:

    solusvm_token = secret:solusvm/<group>/password
FIX

    my @roles = $self->roles;
    return $self->_verdict( 1, "Authenticated as $account->{email} (" . join( ', ', @roles ) . ')', q{} );
}

# Whether the project, plan, location and os image version hypervisors.conf
# names are things this node has.  One wrong fails a provision minutes in, with
# an error from the API rather than from us.
sub check_solusvm_resources {
    my ($self) = @_;

    my $project = eval { $self->project };
    return $self->_verdict( 0, 'No project to build in on ' . $self->describe, "$@" ) unless $project;

    my $plan = eval { $self->plan_detail };
    return $self->_verdict( 0, 'No usable plan on ' . $self->describe, "$@" ) unless $plan;

    my $location = eval { $self->location_id };
    return $self->_verdict( 0, 'No usable location on ' . $self->describe, "$@" ) unless $location;

    my $os      = $self->os;
    my @version = $self->_os_versions;

    # Declared on its own line on purpose.  Declaring and assigning in one
    # statement with a trailing conditional leaves the variable holding whatever
    # it held last time through -- which, for a sub called once per hypervisor
    # in a preflight, is the previous hypervisor's answer.
    my $found;
    $found = first { "$_->{id}" eq "$os" } @version if defined $os && length $os;

    return $self->_verdict( 0, 'Not configured, or not a version this node has: solusvm_os', <<"FIX" ) unless $found;
A guest is installed from an OS image version, and its id is what the API takes.
An image is Debian; a version is Debian 13, and only the version has an id.

@{[ join "\n", map { sprintf '    %-6s %s', $_->{id}, $_->{label} } @version ]}
FIX

    return $self->_verdict( 1, "Builds in project $project as $plan->{name}, running $found->{label}", q{} );
}

# Every OS image version the node offers, labelled the way somebody reading a
# preflight would recognise: the image's name and the version's, together.
sub _os_versions {
    my ($self) = @_;

    my @versions;
    foreach my $image ( $self->_list('get_list_of_os_images') ) {
        push @versions, map { { id => $_->{id}, label => "$image->{name} $_->{version}" } } @{ $image->{versions} // [] };
    }

    return @versions;
}

# Whether there is room for one more guest.  The only limit a SolusVM account
# has that this tool can read is how many servers it may hold.
sub check_solusvm_quota {
    my ($self) = @_;

    my $have = eval { $self->capacity };
    return $self->_verdict( 0, 'Could not read what the account may have on ' . $self->describe, "$@" ) unless $have;

    my $cap = $self->max_guests;
    return $self->_verdict( 0, "The account holds $have->{guests} servers, and its limit is $cap", <<'FIX' ) if $cap && $have->{guests} >= $cap;
Destroy a guest you have finished with, or have the limit raised.  max_guests in
hypervisors.conf can lower this but not raise it: the node enforces its own.
FIX

    my $room = $cap ? "$have->{guests} of $cap servers used" : "$have->{guests} servers, and no limit the node will tell us about";
    return $self->_verdict( 1, "Room to build: $room", q{} );
}

=head2 $address = $hv->provision_guest($config, $seed, %opts)

Ask the node for the guest and hand back the address it turned up at.

A guest that is already there is reinstalled, which keeps its address; C<reuse>
says to provision onto the one that is there rather than reinstalling it.

=cut

sub provision_guest {
    my ( $self, $config, $seed, %opts ) = @_;

    my $domain   = $config->param('domain');
    my $existing = $self->domain_exists($domain);

    if ( $existing && $opts{reuse} ) {
        print "$domain is already on " . $self->describe . "; provisioning onto it\n";
    }
    elsif ($existing) {
        print 'Asking ' . $self->describe . " to reinstall $domain...\n";
        $self->reinstall_guest( $domain, user_data => $seed->{'user-data'} );
    }
    else {
        print 'Asking ' . $self->describe . " for $domain...\n";
        $self->create_guest( name => $domain, user_data => $seed->{'user-data'} );
    }

    my $ip = $self->guest_ssh_ip($config);
    print "$domain is at $ip\n";

    return $ip;
}

=head2 $hv->would_provision($config, %opts)

What the above would do, said rather than done.

=cut

sub would_provision {
    my ( $self, $config, %opts ) = @_;

    my $domain   = $config->param('domain');
    my $existing = $self->domain_exists($domain);
    my $doing    = !$existing ? 'build' : $opts{reuse} ? 'reprovision' : 'reinstall';

    print "Would $doing $domain on " . $self->describe . "\n";

    return $existing ? $self->guest_ssh_ip($config) : '(not built)';
}

=head1 SEE ALSO

L<Trog::HV>, which chose this backend and does the placement arithmetic.

L<SolusVM::Client>, which speaks to the node.

L<Trog::HV::OpenStack>, the other backend that builds by API.

=cut

1;
