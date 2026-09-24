package Trog::HV::SolusVM;

#ABSTRACT: the SolusVM backend: a management node's servers, plans and snapshots.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::HV::Cloud';

use List::Util qw{first};

=head1 NAME

Trog::HV::SolusVM - the SolusVM backend: a management node's servers, plans and
snapshots

=head1 SYNOPSIS

    # Not built directly.  A hypervisors.conf block naming a node gets you one.
    my $hv = Trog::HV->new( solusvm => 'solus.example.test' );

    $hv->create_guest( name => 'vm.example.test', image => 28, size => 2375, user_data => $cloud_config );
    print $hv->guest_ssh_ip($config), "\n";
    $hv->annihilate_domain('vm.example.test');

=head1 DESCRIPTION

A SolusVM management node we ask for guests.  L<Trog::HV::Cloud> holds
everything this answers the same way as any other backend that builds by API;
what is here is what SolusVM does differently.

=over 4

=item * A guest is sized by a B<plan>, which is SolusVM's word for a flavor:
cores, memory and disk together, priced.  The guest names one in its C<_global>
as C<solusvm_plan>, and what plans exist is the node's to say.

=item * It is installed from an B<OS image version>, not an image.  C<Debian> is
the image and C<Debian 13> is the version, and only the version has the id the
API takes.  L</image_for_distro($distro)> is what turns a distro recipe into
one.

=item * B<Placement is the node's.>  It has compute resources and locations, and
it decides which one a plan lands on.  We name a location; we never name a host.

=item * B<Half the API exists twice.>  C</servers> and C</plans> are the whole
node; C</projects/{id}/servers> and C</projects/{id}/plans> are one project's
view of it.  An account with the C<CLIENT> role gets C<403 This action is
unauthorized> from the node-wide half.  This backend uses the project half
throughout, because a token that can administer the node can also see its own
project, and the converse is not true.

=back

=head1 CLASS METHODS

=cut

# How long to wait for a server to be built or reinstalled, and for a deleted
# one to stop being listed.
our $BUILD_TIMEOUT  = 900;
our $DELETE_TIMEOUT = 300;

# How often to ask again while waiting.  A build took about thirty seconds on
# the node this was written against, so this is a handful of requests.
our $POLL = 5;

# What SolusVM charges a plan by, when it charges at all.
our $HOURS_A_MONTH = 730;

my $MB = 1024 * 1024;
my $GB = 1024 * 1024 * 1024;

=head2 config_keys

Returns the F<hypervisors.conf> keys this backend reads.  C<solusvm> marks a
block as one of ours: it names the management node.

=head2 marker

Returns C<solusvm>.  See L<Trog::HV/backend_for(%opts)>.

=head2 size_key

Returns C<solusvm_plan>.  A guest names the plan it is built as in its own
C<_global>, not the block: one node sells many sizes, and which one a guest
wants is the guest's business.

=head2 client_module

Returns L<SolusVM::Client> and the version this backend needs, which
L<Trog::HV/require_client> loads when the client is first built.

=cut

sub config_keys {
    return ( map { $_ => $_ } qw{solusvm solusvm_token solusvm_project solusvm_location domain_dir} );
}
sub marker        { return 'solusvm' }
sub size_key      { return 'solusvm_plan' }
sub client_module { return ( 'SolusVM::Client', '0.001' ) }

=head2 build(%opts)

Returns a new backend object.  Nothing is contacted and the secret store is not
opened, so a script that builds one merely to read a path off it needs neither a
token nor a network.

Dies unless C<solusvm> names a node, and unless C<solusvm_token> is a C<secret:>
reference.  A SolusVM token does not expire and is the whole credential -- a
node with an identity provider in front of it has no password to offer instead
-- so a literal one in the file is refused rather than used.

=cut

sub build {
    my ( $class, %given ) = @_;

    die "A SolusVM hypervisor needs 'solusvm', the hostname of the management node\n"
      unless $given{solusvm};

    die "A SolusVM hypervisor needs solusvm_token, a secret: reference to an API token\n"
      unless $given{solusvm_token};

    die "solusvm_token has to be a secret: reference, not the token itself.  Put the token in the store:\n\n" . "    bin/add_secret --group solusvm --title api\n\n" . "and set solusvm_token = secret:solusvm/api/password\n"
      unless index( $given{solusvm_token}, 'secret:' ) == 0;

    return bless {%given}, $class;
}

=head1 IDENTITY

=head2 describe

=head2 uri

Return what to call this node in a message, and the address of its API.

=cut

# The block's own value rather than setting's, so that a message can never print
# what a secret: reference resolved to.
sub describe ($self) { return 'the SolusVM node ' . $self->{solusvm} }
sub uri      ($self) { return 'https://' . $self->{solusvm} . '/api/v1' }

=head2 location

Returns the location new guests are built in, as F<hypervisors.conf> named it.
It may be a name or an id.

=head2 location_id

Returns the same as the id the API takes, looking it up by name where that is
what the file said.  Dies naming what the node does have, since an id is not
something to guess at.

=cut

sub location ($self) { return $self->setting('solusvm_location') }

sub location_id {
    my ($self) = @_;

    my $wanted = $self->location;
    die 'Building on ' . $self->describe . " needs a location.\nSet solusvm_location in its block in hypervisors.conf.\n"
      unless $wanted;

    my @locations = $self->_list('get_list_of_locations');
    my $found     = first { _is( $_, $wanted ) } @locations;

    die "There is no location '$wanted' on " . $self->describe . ".\nIt has: " . join( ', ', map { "$_->{name} ($_->{id})" } @locations ) . "\n"
      unless $found;

    return $found->{id};
}

=head1 THE API

=head2 api

Returns the L<SolusVM::Client>, and keeps it for later calls.  Built at first
use, so an object that never asks the node anything never opens the store.

=cut

sub api {
    my ($self) = @_;
    return $self->{_api} //= do {
        $self->require_client;
        SolusVM::Client->new( host => $self->{solusvm}, token => $self->setting('solusvm_token') );
    };
}

# Every page of a listing.  The project's plans run to three pages on a node of
# any size, and a plan missed because it was on page two is a build that fails
# saying the plan does not exist.
sub _list {
    my ( $self, $operation, %params ) = @_;
    return grep { ref $_ } $self->api->paginate( $operation, %params );
}

=head2 project

Returns the project guests are built in: what F<hypervisors.conf> named, or the
only one the account has.

Making somebody write down the only possible answer is how a configuration file
grows keys nobody understands, so an account with one project needs no key.  An
account with several is asked, by name and id.

=cut

sub project {
    my ($self) = @_;

    my $named = $self->setting('solusvm_project');
    return $named            if $named;
    return $self->{_project} if $self->{_project};

    my @projects = $self->_list('get_list_of_projects');

    die 'The account on ' . $self->describe . " has no projects, so there is nowhere to build.\n"
      unless @projects;

    die 'The account on ' . $self->describe . ' has ' . scalar(@projects) . " projects, so one has to be named.\n" . 'Set solusvm_project in its block in hypervisors.conf to one of: ' . join( ', ', map { "$_->{name} ($_->{id})" } @projects ) . "\n"
      if @projects > 1;

    return $self->{_project} = $projects[0]{id};
}

sub _account {
    my ($self) = @_;
    return $self->{_account} //= $self->api->get_user_info()->{data} // {};
}

=head2 roles

Returns what the token's account may do, as the node names it.  C<CLIENT> is an
account that uses the node; anything else administers some part of it.

=cut

sub roles {
    my ($self) = @_;
    return map { $_->{name} // () } @{ $self->_account->{roles} // [] };
}

=head1 WHAT THE NODE SELLS

=head2 plans

Returns every plan the project may build with.

=head2 plan($wanted)

Returns one of them, by id or by name -- F<provision.conf> may say either, and a
plan is called something like C<c8.d80.r1024 - Shared LVM>, which nobody wants
to type twice.

=cut

sub plans {
    my ($self) = @_;
    return @{ $self->{_plans} //= [ $self->_list( 'get_list_of_project_plans', id => $self->project ) ] };
}

sub plan {
    my ( $self, $wanted ) = @_;

    my $found = first { _is( $_, $wanted ) } $self->plans;

    die "There is no plan '$wanted' on " . $self->describe . ".\n" . 'The project has ' . scalar( $self->plans ) . " to choose from.\n"
      unless $found;

    return $found;
}

# Whether a thing the node listed is the one named, by id or by name.  Both,
# because a configuration may say either and the name is the readable one.
sub _is {
    my ( $thing, $wanted ) = @_;
    return 1 if defined $thing->{id}   && "$thing->{id}" eq "$wanted";
    return 1 if defined $thing->{name} && $thing->{name} eq $wanted;
    return 0;
}

=head2 image_for_distro($distro)

Returns the id of the OS image version that installs this distro recipe's
release.

Unlike the other backends' answers this one is a number the node issued, so it
has to be asked for rather than spelled out: C<Debian> is an image and
C<Debian 13> is a version under it, and the id belongs to the version.

=cut

sub image_for_distro {
    my ( $self, $distro ) = @_;

    my $wanted  = lc $distro->distribution;
    my $release = $distro->release_version;

    foreach my $image ( $self->_list('get_list_of_os_images') ) {
        next unless lc( $image->{name} // q{} ) eq $wanted;

        my $version = first { ( $_->{version} // q{} ) eq $release } @{ $image->{versions} // [] };
        return $version->{id} if $version;
    }

    die 'There is no ' . $distro->distribution . " $release on " . $self->describe . ".\n" . "It has: " . join( ', ', map { $_->{label} } $self->_os_versions ) . "\n";
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

=head2 cheapest_for(%needs)

Returns the cheapest plan the project sells that holds a guest wanting
C<memory_mb>, C<cpus> and C<disk_bytes>, as L<Trog::HV/cheapest_for(%needs)>
returns one.  Undef when no plan holds it, or when the node cannot be asked.

A plan priced at nothing sorts as nothing, which is the truth on a node that
bills elsewhere: every plan on the one this was written against costs zero
tokens, so the cheapest that fits is simply the smallest.

=cut

sub cheapest_for {
    my ( $self, %needs ) = @_;

    my @fit = eval {
        grep { _holds( $_, %needs ) } $self->plans;
    };
    return undef unless @fit;

    my @priced = sort { $a->{monthly_cost} <=> $b->{monthly_cost} || $a->{params}{ram} <=> $b->{params}{ram} } map { +{ %{$_}, monthly_cost => _monthly($_) } } @fit;

    return {
        key          => $self->size_key,
        value        => $priced[0]{id},
        monthly_cost => $priced[0]{monthly_cost},
    };
}

=head2 monthly_cost(%needs)

Returns what the plan the guest names costs a month.

=cut

sub monthly_cost {
    my ( $self, %needs ) = @_;

    my $named = $needs{ $self->size_key } or return 0;
    return _monthly( $self->plan($named) );
}

# A plan says what it costs a month, or only what it costs an hour.  An hourly
# one is reported at a month of hours, so that two plans can be compared at all.
sub _monthly {
    my ($plan) = @_;
    return $plan->{tokens_per_month} if $plan->{tokens_per_month};
    return ( $plan->{tokens_per_hour} // 0 ) * $HOURS_A_MONTH;
}

sub _holds {
    my ( $plan, %needs ) = @_;
    my $params = $plan->{params} // {};

    return 0 if ( $params->{ram} // 0 ) < ( $needs{memory_mb} // 0 ) * $MB;
    return 0 if ( $params->{vcpu} // $params->{cores} // 0 ) < ( $needs{cpus} // 0 );
    return 0 if ( $params->{disk} // 0 ) * $GB < ( $needs{disk_bytes} // 0 );
    return 1;
}

=head1 CAPACITY

=head2 capacity(%needs)

Returns what the guest would get, in the shape L<Trog::HV/shortfalls(%needs)>
reads: the plan it names, and how many servers the project already holds.

The size figures are one guest's rather than a fleet's, and deliberately.  The
node runs its own placement, so there is no free-memory figure here that means
what it means on a machine, and inventing one would put this tool in the
business of second-guessing a scheduler it cannot see.  What the shape then says
is the true thing: a guest asking for more than its plan provides does not fit.

=head2 reserve_memory, reserve_cpus, reserve_disk

Return nothing, whatever F<hypervisors.conf> says.  A reserve is what is left
for a host we share; we do not share this node's hosts and cannot see them, and
holding back a slice of a plan that is sold whole would only refuse guests the
node would have built.

=cut

sub capacity {
    my ( $self, %needs ) = @_;

    my $named = $needs{ $self->size_key };
    die 'A guest is built on ' . $self->describe . " as the plan it names in solusvm_plan, and this one names none\n"
      unless $named;

    my $params = $self->plan($named)->{params} // {};

    my $memory_mb = int( ( $params->{ram} // 0 ) / $MB );
    my $cpus      = $params->{vcpu} // $params->{cores} // 0;

    return {
        memory_mb        => $memory_mb,
        memory_committed => 0,
        memory_free      => $memory_mb,
        cpus             => $cpus,
        cpus_allocatable => $cpus,
        cpus_committed   => 0,
        cpus_free        => $cpus,
        disk_free        => ( $params->{disk} // 0 ) * $GB,
        guests           => scalar $self->servers,
    };
}

sub reserve_memory { return 0 }
sub reserve_cpus   { return 0 }
sub reserve_disk   { return 0 }

=head2 max_guests

Returns the account's own limit on how many servers it may hold, unless
F<hypervisors.conf> set something lower.  An account in no limit group has none
that this tool can read, and 0 is how that is spelled.

=cut

sub max_guests {
    my ($self) = @_;
    return $self->{max_guests} if $self->{max_guests};
    return ( $self->_account->{limit_usage} // {} )->{servers} // 0;
}

=head2 shortfalls(%needs)

Returns every reason this node cannot take the guest.  A guest that names no
plan is not built here at all, which is the first of them.

=cut

sub shortfalls {
    my ( $self, %needs ) = @_;

    return 'names no solusvm_plan, so it is not built on a SolusVM node' unless $needs{ $self->size_key };
    return $self->SUPER::shortfalls(%needs);
}

=head1 GUESTS

A guest is a server whose name is the domain name, which is the identity every
other backend uses too.

=head2 servers

=head2 server($name)

Return every server in the project, and the one called C<$name>.

C<server> dies where two share the name rather than picking one: the next thing
done with the answer rebuilds it or deletes it.

=cut

sub servers {
    my ($self) = @_;
    return $self->_list( 'get_list_of_project_servers', id => $self->project );
}

sub server {
    my ( $self, $name ) = @_;

    my @found = grep { ( $_->{name} // q{} ) eq $name } $self->servers;

    die 'There are ' . scalar(@found) . " servers called '$name' on " . $self->describe . ".\n" . "A name is how this tool identifies a guest, so it will not guess which you meant.\n"
      if @found > 1;

    return $found[0];
}

=head2 guest_names

=head2 domain_exists($name)

Return every server in the project, whatever built it, and whether one of them
is this guest.  Not only ours: an orphan sweep asks whether anything is still
using a name, and one somebody else created is.

=cut

sub guest_names ($self) {
    return map { $_->{name} // () } $self->servers;
}
sub domain_exists ( $self, $name ) { return defined $self->server($name) ? 1 : 0 }

=head2 guest_ssh_ip($config, $lease)

Returns the address to reach a guest at: its primary IPv4, which is the one the
node's own panel and DNS show.  C<$lease> is libvirt's and is ignored, so that
F<bin/provision> can ask either kind of backend the same way.

=cut

sub guest_ssh_ip {
    my ( $self, $config, $_lease ) = @_;

    my $name = ref $config ? $config->param('domain') : $config;

    my $server = $self->_detail($name)
      or die "There is no guest called '$name' on " . $self->describe . "\n";

    my @addresses = @{ $server->{ip_addresses}{ipv4} // [] };

    my $primary = first { $_->{is_primary} } @addresses;
    return $primary->{ip}    if $primary   && $primary->{ip};
    return $addresses[0]{ip} if @addresses && $addresses[0]{ip};

    die "The guest '$name' has no IPv4 address to reach it at.\n" . 'It is ' . ( $server->{status} // 'in no state the node would name' ) . "; a server still being built has none yet.\n";
}

# A listing is abbreviated, and addresses are not on it.
sub _detail {
    my ( $self, $name ) = @_;

    my $server = $self->server($name) or return undef;
    return $self->api->get_an_existing_server( id => $server->{id} )->{data};
}

=head1 SNAPSHOTS

A SolusVM snapshot belongs to its server, so unlike an image of a whole project
it needs no prefix to say whose it is.

=head2 snapshot_names($domain)

Returns them newest first.

=cut

sub snapshot_names {
    my ( $self, $domain ) = @_;
    return map { $_->{name} // () } $self->_snapshots($domain);
}

sub _snapshots {
    my ( $self, $domain ) = @_;

    my $server = $self->server($domain)
      or die "There is no guest called '$domain' to ask about snapshots\n";

    my @newest_last = sort { ( $a->{created_at} // q{} ) cmp ( $b->{created_at} // q{} ) } $self->_list( 'get_list_of_server_snapshots', id => $server->{id} );
    return reverse @newest_last;
}

=head2 create_snapshot($domain, $name)

=head2 revert_snapshot($domain, $name)

Take one, and put the guest back on one.  Reverting is by the snapshot's own id,
which is what the node's endpoint takes, so the snapshot is found first.

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

    my $snapshot = first { ( $_->{name} // q{} ) eq $name } $self->_snapshots($domain);
    die "The guest '$domain' has no snapshot called '$name'\n" unless $snapshot;

    $self->api->revert_snapshot( id => $snapshot->{id} );
    return 1;
}

=head1 BUILDING AND TEARING DOWN

=head2 create_guest(%spec)

Builds a guest and waits until the node reports it started.

C<name> is required, as are C<size>, the plan the guest names in
C<solusvm_plan>, and C<image>, the OS image version id that
L</image_for_distro($distro)> answered when F<bin/new_config> wrote the guest's
F<provision.conf>.  C<location> defaults to the block's.  C<user_data> is the
cloud-init payload, which the node hands the guest itself.

Returns the server.

=cut

sub create_guest {
    my ( $self, %spec ) = @_;

    my $name = $spec{name};
    die "create_guest needs a name\n" unless $name;

    die "Building '$name' on " . $self->describe . " needs an image, which the distro recipe decides\n"     unless $spec{image};
    die "Building '$name' on " . $self->describe . " needs a size, which the guest names in solusvm_plan\n" unless $spec{size};

    my %optional;
    $optional{user_data} = $spec{user_data} if $spec{user_data};

    # The project endpoint's body is not the node-wide one's: plan_id rather
    # than plan, and so on down.  They are separate operations with separate
    # schemas, and only one of them answers for an account with the CLIENT role.
    my $made = $self->api->create_a_new_project_server(
        id                  => $self->project,
        name                => $name,
        plan_id             => $self->plan( $spec{size} )->{id},
        location_id         => $spec{location} // $self->location_id,
        os_image_version_id => $spec{image},
        %optional,
    );

    return $self->_wait_for_started( $made->{data}{id}, $name );
}

=head2 rebuild_guest($name, image => $image, user_data => $seed)

Puts the OS back on a guest that exists, with a fresh cloud-init payload, and
waits for it to come back.

The server survives, and so does its address, which is the whole reason to
prefer this to deleting and building again.  The payload is the point: it
carries the key F<bin/provision> has just generated, and a reinstall that kept
the old one would bring the guest up locked against us.

=cut

sub rebuild_guest {
    my ( $self, $name, %spec ) = @_;

    my $server = $self->server($name)
      or die "There is no guest called '$name' to rebuild\n";

    my $image = $spec{image};
    die "Rebuilding '$name' on " . $self->describe . " needs an image, which the distro recipe decides\n" unless $image;

    my %optional;
    $optional{user_data} = $spec{user_data} if $spec{user_data};

    # 'os' here, where creating one says 'os_image_version_id'.  The two
    # operations name the same thing differently, which catalog() in
    # SolusVM::Client is where to see.
    $self->api->reinstall_server( id => $server->{id}, os => $image, %optional );

    # The node says started for a moment after it takes the request, so waiting
    # for started alone returns before the reinstall has begun.
    $self->_wait_for_change( $server->{id}, $name );
    return $self->_wait_for_started( $server->{id}, $name );
}

# Wait until the node stops calling the server started, so that the wait for it
# to be started again is waiting for this reinstall rather than seeing the state
# the last one left.
sub _wait_for_change {
    my ( $self, $id, $name ) = @_;

    my $deadline = time + $BUILD_TIMEOUT;
    while ( time < $deadline ) {
        my $detail = $self->api->get_an_existing_server( id => $id )->{data} // {};
        return 1 if ( $detail->{status} // q{} ) ne 'started' || $detail->{is_processing};
        sleep $POLL;
    }

    die "The node never started reinstalling '$name'; it still says the guest is up.\n";
}

# Poll until the node has finished with the server.
#
# Waits for 'started' rather than watching the states in between, because the
# states in between are not all documented: the API reference gives status five
# values, and a server part way through a reinstall reports a sixth,
# 'reinstalling', seen on a live one.  Treating anything that is not 'started'
# as still working is what makes that a non-event, and only 'unavailable' is
# worth giving up on, because it is the one the node will not leave by itself.
sub _wait_for_started {
    my ( $self, $id, $name ) = @_;

    my $deadline = time + $BUILD_TIMEOUT;

    while (1) {
        my $detail = $self->api->get_an_existing_server( id => $id )->{data} // {};
        my $status = $detail->{status}                                       // q{};

        return $detail if $status eq 'started' && !$detail->{is_processing};

        die "Building '$name' left it unavailable, which it will not come out of on its own.\n"
          if $status eq 'unavailable';

        last if time >= $deadline;
        sleep $POLL;
    }

    die "The guest '$name' had not started ${BUILD_TIMEOUT}s after being asked for.\n" . "Look at it in the panel: a task that failed stays failed.\n";
}

=head2 annihilate_domain($name)

Takes the guest away.  Returns false when there was no such guest, which makes
it safe to call on a name that may already be gone.

=cut

sub annihilate_domain {
    my ( $self, $name ) = @_;

    my $server = $self->server($name);
    return 0 unless $server;

    $self->api->delete_server( id => $server->{id} );

    # The node's delete is a task rather than an act, so the server is listed
    # for a while after it is accepted.  A task that failed looks exactly like
    # a slow one until the wait runs out.
    my $deadline = time + $DELETE_TIMEOUT;
    sleep $POLL while $self->server($name) && time < $deadline;

    die "The guest '$name' was still listed ${DELETE_TIMEOUT}s after being deleted.\n" . "Look at the task in the panel: one that failed will not retry itself.\n"
      if $self->server($name);

    return 1;
}

=head1 PREFLIGHT

=head2 @names = $hv->preflight_checks(), $hv->preflight_notes()

Return the names of the checks and notes that C<bin/preflight> runs on this
backend, in order.  See L<Trog::HV/PREFLIGHT>.

=cut

sub preflight_checks { return qw{check_client check_reachable check_solusvm_resources check_solusvm_quota check_rsync check_transfer_ip check_transfer_route check_fetch_sources check_config} }
sub preflight_notes  { return qw{note_stale_image note_apt_mirror note_plaintext_secrets} }

=head2 $result = $hv->check_reachable()

Returns whether the token works, and says which account it belongs to and what
that account may do.  Everything below needs this to have worked.

=cut

sub check_reachable {
    my ($self) = @_;

    my $account = eval { $self->_account };
    return $self->_verdict( 0, 'Could not reach ' . $self->describe . ' with that token', <<"FIX" ) unless $account && $account->{email};
$@
A SolusVM token is made in the panel under Account and does not expire, so one
that has stopped working has been revoked, or belongs to an account that has.
FIX

    return $self->_verdict( 1, "Authenticated as $account->{email} (" . join( ', ', $self->roles ) . ')', q{} );
}

=head2 $result = $hv->check_solusvm_resources()

Returns whether the project and location this block names are things the node
has.  One wrong fails a provision minutes in, with an error from the API rather
than from us.

What plan a guest is built as is not checked here, because it is not the
block's: a guest names it, and L</shortfalls(%needs)> is where a guest that
names one the node does not sell is refused.

=cut

sub check_solusvm_resources {
    my ($self) = @_;

    my $project = eval { $self->project };
    return $self->_verdict( 0, 'No project to build in on ' . $self->describe, "$@" ) unless $project;

    my $location = eval { $self->location_id };
    return $self->_verdict( 0, 'Not configured, or not a location this node has: solusvm_location', "$@" ) unless $location;

    my $plans = scalar $self->plans;
    return $self->_verdict( 1, "Builds in project $project at location $location, from $plans plans", q{} );
}

=head2 $result = $hv->check_solusvm_quota()

Returns whether there is room for one more guest.  How many servers it may hold
is the only limit on a SolusVM account that this tool can read.

=cut

sub check_solusvm_quota {
    my ($self) = @_;

    my $held = eval { scalar $self->servers };
    return $self->_verdict( 0, 'Could not count what the account holds on ' . $self->describe, "$@" ) unless defined $held;

    my $cap = $self->max_guests;
    return $self->_verdict( 0, "The account holds $held servers, and its limit is $cap", <<'FIX' ) if $cap && $held >= $cap;
Destroy a guest you have finished with, or have the limit raised.  max_guests in
hypervisors.conf can lower this but not raise it: the node enforces its own.
FIX

    return $self->_verdict( 1, 'Room to build: ' . ( $cap ? "$held of $cap servers used" : "$held servers, and no limit the node will tell us about" ), q{} );
}

=head1 SEE ALSO

L<Trog::HV::Cloud>, which holds what this shares with every backend that builds
by API.

L<SolusVM::Client>, which speaks to the node.

L<Trog::HV::Linode> and L<Trog::HV::OpenStack>, the other two.

=cut

1;
