package Trog::HV::Linode;

#ABSTRACT: the Linode backend: a guest is a Linode, bought by the month.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::HV::Cloud';

use List::Util qw{any sum0};
use MIME::Base64();
use Cpanel::JSON::XS();
use Crypt::PRNG();
use Linode::API 0.002 ();

=head1 NAME

Trog::HV::Linode - the Linode backend: a guest is a Linode, bought by the month

=head1 SYNOPSIS

    ; hypervisors.conf
    [linode]
    linode_token   = secret:linode/api/password
    region         = us-east
    type           = g6-standard-2
    monthly_budget = 200

=head1 DESCRIPTION

This backend builds each guest as a Linode, through the Linode API, with
L<Linode::API>.  It is a L<Trog::HV::Cloud>: Linode creates the guest, assigns
its addresses, and takes the cloud-init payload as metadata, so there is no
host to reach, no pool and no seed drive.

What makes it unlike the other backends is that a guest costs money.  A block
names one Linode type, and every guest built on it is that type, at that type's
price in that region.  So:

=over 4

=item * A guest fits if the type has the memory, the vCPUs and the disk that
the guest asks for.  A guest that asks for less gets the type anyway, and pays
for it.

=item * L</monthly_cost(%needs)> is the type's monthly price, which Linode's API
reports.  Placement puts a guest on a machine we own before this, because a
machine we own costs nothing more for one more guest.  See
L<Trog::Hypervisors/place($domain, %needs)>.

=item * C<monthly_budget> caps what the whole account costs a month.  A guest
that would take the account over it does not fit.

=back

The token lives in the secret store, as a reference.  Reading it needs the
passphrase of the store, so the first call to the API asks for it, as a run
that fills in the C<secret:> notes of a configuration does.

=head1 CLASS METHODS

=cut

# Written as a tag on every guest this tool builds, and on its snapshots.
our $MANAGED_BY = 'trog-provisioner';

# Where the API is, for the messages that name where a guest is built.
our $API_URL = 'https://api.linode.com/v4';

# Seconds to wait for a Linode to reach a state, and between two looks at it.
our $BUILD_TIMEOUT  = 900;
our $IMAGE_TIMEOUT  = 3600;
our $BUSY_TIMEOUT   = 300;
our $DELETE_TIMEOUT = 300;
our $POLL           = 5;

# What Linode reports in megabytes.
my $MB = 1024 * 1024;

=head2 config_keys

Returns the F<hypervisors.conf> keys that this backend reads.  C<linode_token>
marks a block as one for this backend.

=head2 marker

Returns C<linode_token>, the option that makes a block a Linode one.  See
L<Trog::HV/backend_for(%opts)>.

=cut

sub config_keys {
    return ( map { $_ => $_ } qw{linode_token region firewall_id private_ip monthly_budget domain_dir} );
}
sub marker   { return 'linode_token' }
sub size_key { return 'linode_type' }

=head2 build(%opts)

Returns a new backend object.  It does not contact Linode, so a script can
build it to read a path off it without the token.

Dies unless C<linode_token> is a C<secret:> reference.  The token is written
nowhere in the clear, so a literal one is refused rather than used.

=cut

sub build {
    my ( $class, %given ) = @_;

    die "A Linode hypervisor needs linode_token, a secret: reference to the API token\n"
      unless $given{linode_token};
    die "linode_token has to be a secret: reference, not the token itself.  Put the token in the store:\n\n" . "    bin/add_secret --group linode --title api\n\n" . "and set linode_token = secret:linode/api/password\n"
      unless index( $given{linode_token}, 'secret:' ) == 0;

    return bless {%given}, $class;
}

=head1 IDENTITY

=head2 describe

Returns a name for the account and region, for a diagnostic message.

=head2 uri

Returns the address of the API, so that a message about where a guest is built
has a correct value to show.

=cut

# The block's value rather than setting's, so that a message never prints what
# a secret: reference resolved to.
sub describe ($self) { return 'Linode' . ( $self->{region} ? " in $self->{region}" : q{} ) }
sub uri              { return $API_URL }

=head2 region, firewall_id, private_ip, monthly_budget

Return the values that F<hypervisors.conf> set.  C<region> has no default,
because there is no safe guess at where a guest runs.  C<firewall_id> names a
Cloud Firewall to put a new guest behind, and C<private_ip> gives it an address
on Linode's private network.  C<monthly_budget> is in the currency Linode bills
in.

What a guest boots is not the block's to say: see L</image_for_distro($distro)>.
Neither is what size it is.  A guest names that in its C<_global>, as
C<linode_type>, and one that names none is not built here at all: see
L</shortfalls(%needs)>.

=cut

sub region         ($self) { return $self->setting('region') }
sub firewall_id    ($self) { return $self->setting('firewall_id') }
sub private_ip     ($self) { return $self->setting('private_ip') }
sub monthly_budget ($self) { return $self->setting('monthly_budget') }

=head1 THE API

=head2 api

Returns the L<Linode::API> client, and keeps it for later calls.  It is built
at first use, so an object that never calls Linode never opens the secret
store.

=cut

sub api {
    my ($self) = @_;
    return $self->{_api} //= Linode::API->new( token => $self->_token );
}

sub _token { my ($self) = @_; return $self->setting('linode_token') }

# One call, answered with Linode's JSON.  Dies with what Linode said, or with
# what the specification said was wrong before anything was sent.
#
# Linode refuses an action on a Linode that is still doing the last one, as
# "Linode busy.", and that passes: so it is asked again until $BUSY_TIMEOUT.
sub _call {
    my ( $self, $operation, $params, @body ) = @_;

    my $deadline = time + $BUSY_TIMEOUT;
    my ( $tx, $reasons );
    do {
        sleep $POLL if $tx;
        $tx = $self->api->call( $operation, $params // {}, @body );
        return $tx->res->json unless $tx->error;

        my @errors = @{ ( $tx->res->json // {} )->{errors} // [] };
        $reasons = join(
            '; ',
            map {
                join( ': ', grep { defined } $_->{field} // $_->{path}, $_->{reason} // $_->{message} )
            } @errors
        );
    } while ( ( $tx->error->{code} // 0 ) == 400 && $reasons =~ m/\ALinode[ ]busy/i && time < $deadline );

    my $error = $tx->error;
    die "Linode refused $operation: " . ( $error->{code} ? "$error->{code} " : q{} ) . ( $reasons || $error->{message} ) . "\n";
}

# Every page of a list, which Linode hands out 500 at a time at most.
sub _all {
    my ( $self, $operation, $params ) = @_;

    my ( @all, $page, $pages );
    do {
        my $answer = $self->_call( $operation, { %{ $params // {} }, page => ++$page, page_size => 500 } );
        push @all, @{ $answer->{data} // [] };
        $pages = $answer->{pages} // 1;
    } while ( $page < $pages );

    return @all;
}

sub _filter ($query) { return Cpanel::JSON::XS::encode_json($query) }

=head1 WHAT A GUEST COSTS

=head2 monthly_cost(%needs)

The monthly price, in this block's region, of the type the guest names in
C<linode_type>.  Linode prices a type differently in some regions, and the
region's price is the one that it bills.

Dies when the guest names no type, when C<region> is not set, or when Linode
has no such type.  L</shortfalls(%needs)> answers for a guest that names none
before anything asks its price.

=cut

sub monthly_cost {
    my ( $self, %needs ) = @_;

    my $type = $needs{ $self->size_key };
    die 'A guest is built on ' . $self->describe . " as the type it names in linode_type, and this one names none
" unless $type;
    die 'Say which region to build in, in the block for ' . $self->describe . " in hypervisors.conf
" unless $self->region;

    return $self->_price( $type, $self->region );
}

=head2 monthly_spend

What every Linode on the account costs a month now, with the backup service
where it is on.  It counts Linodes that something else built too, because the
budget is for the account.  It does not count images, volumes or transfer,
which are small beside the Linodes and billed by use.

=cut

sub monthly_spend {
    my ($self) = @_;

    return sum0 map {
        my $linode = $_;
        $self->_price( $linode->{type}, $linode->{region} ) + ( $linode->{backups}{enabled} ? $self->_price( $linode->{type}, $linode->{region}, 'backups' ) : 0 )
    } $self->_linodes;
}

# The monthly price of a type in a region, or of its backup service.
sub _price {
    my ( $self, $type_id, $region, $addon ) = @_;

    my $type = $self->_type($type_id);
    my $item = $addon ? $type->{addons}{$addon} : $type;

    my ($local) = grep { $_->{id} eq $region } @{ $item->{region_prices} // [] };
    my $monthly = ( $local // $item->{price} // {} )->{monthly};

    die "Linode reports no monthly price for $type_id" . ( $addon ? " $addon" : q{} ) . " in $region\n"
      unless defined $monthly;

    return $monthly;
}

# Every type Linode sells, which does not change within a run.
sub _type {
    my ( $self, $id ) = @_;

    $self->{_types} //= { map { $_->{id} => $_ } $self->_all('get-linode-types') };
    return $self->{_types}{$id} // die "Linode has no type '$id'\n";
}

=head2 image_for_distro($distro)

The Linode image for the distro's distribution and release, which Linode names
by both run together: C<linode/ubuntu24.04>.  Whether Linode has it, and whether
it reads cloud-init, is C<check_linode_resources>'s to find out before a build.

=cut

sub image_for_distro ( $, $distro ) { return 'linode/' . $distro->distribution . $distro->release_version }

=head2 cheapest_for(%needs)

The cheapest type Linode sells that holds a guest wanting C<memory_mb>,
C<cpus> and C<disk_bytes>, as L<Trog::HV/cheapest_for(%needs)> returns one.

A type that would take the account over C<monthly_budget> is not offered: an
offer that cannot be accepted is noise.  Undef when no type holds the guest,
when the budget leaves room for none, or when Linode cannot be asked.

=cut

sub cheapest_for {
    my ( $self, %needs ) = @_;

    my @fit = eval {
        grep { $_->{memory} >= ( $needs{memory_mb} // 0 ) && $_->{vcpus} >= ( $needs{cpus} // 0 ) && $_->{disk} * $MB >= ( $needs{disk_bytes} // 0 ) } $self->_all('get-linode-types');
    };
    return undef unless @fit;

    my $room = $self->monthly_budget ? $self->monthly_budget - $self->monthly_spend : undef;

    my @priced =
      sort { $a->{monthly_cost} <=> $b->{monthly_cost} || $a->{memory} <=> $b->{memory} }
      grep { !defined $room                            || $_->{monthly_cost} <= $room }
      map {
        my $type = $_;
        +{ %$type, monthly_cost => eval { $self->_price( $type->{id}, $self->region ) } // 0 }
      } @fit;

    return undef unless @priced;
    return { key => $self->size_key, value => $priced[0]{id}, monthly_cost => $priced[0]{monthly_cost} };
}

=head1 CAPACITY

=head2 capacity(%needs)

As L<Trog::HV/capacity(%needs)>, for one guest of the type it names in
C<linode_type>: that type's memory, vCPUs and disk, with nothing committed
against them, because every guest gets a Linode of its own.  C<guests> is the
number of Linodes on the account.

Dies when the guest names no type, which L</shortfalls(%needs)> answers for
first.

=head2 reserve_memory, reserve_cpus, reserve_disk

0.  A reserve keeps something back for a host, and there is no host here to
keep it for.

=cut

sub capacity {
    my ( $self, %needs ) = @_;

    my $named = $needs{ $self->size_key };
    die 'A guest is built on ' . $self->describe . " as the type it names in linode_type, and this one names none
" unless $named;

    my $type = $self->_type($named);

    return {
        memory_mb        => $type->{memory},
        memory_committed => 0,
        memory_free      => $type->{memory},
        cpus             => $type->{vcpus},
        cpus_allocatable => $type->{vcpus},
        cpus_committed   => 0,
        cpus_free        => $type->{vcpus},
        disk_free        => $type->{disk} * $MB,
        guests           => scalar $self->_linodes,
    };
}

sub reserve_memory { return 0 }
sub reserve_cpus   { return 0 }
sub reserve_disk   { return 0 }

=head2 shortfalls(%needs)

As L<Trog::HV/shortfalls(%needs)>, and two more.  A guest that names no
C<linode_type> is not built here at all, which is how a guest is kept off
Linode on purpose.  And a guest that would take what the account costs a month
over C<monthly_budget> does not fit.

=cut

sub shortfalls {
    my ( $self, %needs ) = @_;

    return 'names no linode_type, so it is not built on Linode' unless $needs{ $self->size_key };

    my @reasons = $self->SUPER::shortfalls(%needs);
    return @reasons unless $self->monthly_budget;

    my $spend = $self->monthly_spend;
    my $cost  = $self->monthly_cost(%needs);

    push @reasons, sprintf( 'a %s costs %.2f a month, and the account already costs %.2f of its monthly_budget of %.2f', $needs{ $self->size_key }, $cost, $spend, $self->monthly_budget )
      if $spend + $cost > $self->monthly_budget;

    return @reasons;
}

=head1 GUESTS

A guest is a Linode whose label is the domain name.  Linode keeps a label unique
within an account.

=head2 linode($name)

Returns the Linode labeled C<$name>, or nothing.  Dies when C<$name> is empty.

=cut

sub linode {
    my ( $self, $name ) = @_;

    die "linode() needs a name\n" unless $name;

    my @found = grep { $_->{label} eq $name } $self->_all( 'get-linode-instances', { 'X-Filter' => _filter( { label => $name } ) } );
    return $found[0];
}

sub _linodes ($self) { return $self->_all('get-linode-instances') }

=head2 guest_names

Returns the label of every Linode on the account, whatever built it.  An orphan
sweep asks whether anything still uses a name, and one that somebody else
built still does.

=head2 domain_exists($name)

Returns 1 if there is a Linode labeled C<$name>, in any state, and 0 if there
is not.

=cut

sub guest_names ($self) {
    return map { $_->{label} } $self->_linodes;
}

sub domain_exists ( $self, $name ) { return defined $self->linode($name) ? 1 : 0 }

=head2 guest_ssh_ip($config, $lease)

Returns the public IPv4 address of a guest.  C<$config> is the configuration of
the domain, or the domain name.  C<$lease> is for libvirt, and this backend
ignores it.

Dies when there is no such guest, or it has no public IPv4 address.

=cut

sub guest_ssh_ip {
    my ( $self, $config, $_lease ) = @_;

    my $name = ref $config ? $config->param('domain') : $config;

    my $linode = $self->linode($name)
      or die "There is no guest called '$name' on " . $self->describe . "\n";

    my ($public) = grep { !_is_private($_) } @{ $linode->{ipv4} // [] };
    return $public // die "The guest '$name' has no public IPv4 address on " . $self->describe . "\n";
}

# A private address routes only inside Linode's own network, and Linode takes
# them from 192.168.128.0/17.  The rest of RFC 1918 is here for a VPC.
sub _is_private ($address) { return $address =~ m/\A(?:10[.]|192[.]168[.]|172[.](?:1[6-9]|2\d|3[01])[.])/ ? 1 : 0 }

=head1 BUILDING AND TEARING DOWN

=head2 create_guest(%spec)

Builds a guest, and waits until Linode reports it C<running>.

C<name> is required, and is the label.  So is C<size>, the type the guest
names in C<linode_type>, and C<image>, which
L</image_for_distro($distro)> answered when F<bin/new_config> wrote the guest's
F<provision.conf>.  C<region> and C<type> default to the values in
F<hypervisors.conf>.  C<user_data> is the cloud-init payload, which Linode's
metadata service gives to the guest.

The root password is random and kept nowhere.  Every login is by ssh key, and
Linode can reset the password if the console is ever needed.

Returns the Linode.  Dies when C<name>, C<region>, C<type> or C<image> has no
value, when C<name> is not a label Linode takes, or when the Linode does not
come up in C<$BUILD_TIMEOUT> seconds.

=cut

sub create_guest {
    my ( $self, %spec ) = @_;

    my $name = $spec{name};
    die "create_guest needs a name\n" unless $name;
    die "Linode labels are 64 characters at most, and '$name' is longer\n" if length $name > 64;

    die "Building '$name' on " . $self->describe . " needs an image, which the distro recipe decides
" unless $spec{image};
    die "Building '$name' on " . $self->describe . " needs a size, which the guest names in linode_type
" unless $spec{size};

    $spec{region} //= $self->region;
    die "Building '$name' on " . $self->describe . " needs 'region'.
Set it in the block in hypervisors.conf.
" unless $spec{region};

    my %body = (
        label     => $name,
        region    => $spec{region},
        type      => $spec{size},
        image     => $spec{image},
        root_pass => _root_pass(),
        tags      => [$MANAGED_BY],
        booted    => Cpanel::JSON::XS::true(),
        _metadata( $spec{user_data} ),
    );
    $body{firewall_id} = 0 + $self->firewall_id   if $self->firewall_id;
    $body{private_ip}  = Cpanel::JSON::XS::true() if $self->private_ip;

    my $linode = $self->_call( 'post-linode-instance', {}, json => \%body );
    return $self->_wait_for( $linode->{id}, $name, 'running' );
}

=head2 rebuild_guest($name, user_data => $seed, image => $image)

Deploys the image again over a guest that exists, with a new cloud-init
payload, and waits until it is C<running> again.  C<image> is required: the
guest's own, from its F<provision.conf>, or a snapshot's.

Linode keeps the Linode and its addresses, and deletes its disks.  When the
guest is not the type in F<hypervisors.conf>, the rebuild resizes it to that
type.

Returns the Linode.  Dies when there is no such guest or no image, or when it
does not come back in C<$BUILD_TIMEOUT> seconds.

=cut

sub rebuild_guest {
    my ( $self, $name, %spec ) = @_;

    my $linode = $self->linode($name)
      or die "There is no guest called '$name' to rebuild\n";

    my $image = $spec{image};
    die "Rebuilding '$name' on " . $self->describe . " needs an image, which the distro recipe decides\n" unless $image;

    my %body = ( image => $image, root_pass => _root_pass(), booted => Cpanel::JSON::XS::true(), _metadata( $spec{user_data} ) );
    $body{type} = $spec{size} if $spec{size} && $spec{size} ne $linode->{type};

    $self->_call( 'post-rebuild-linode-instance', { linodeId => $linode->{id} }, json => \%body );

    # Linode still says running for a moment after it takes the request, so
    # waiting for running alone returns before the rebuild has begun.
    $self->_wait_for_change( $linode->{id}, $name, 'running' );
    return $self->_wait_for( $linode->{id}, $name, 'running' );
}

# Linode takes the payload base64 encoded, for its metadata service to hand to
# cloud-init, and refuses one over 64KB before encoding.
sub _metadata ($user_data) {
    return () unless $user_data;
    die 'The cloud-init payload is ' . length($user_data) . " bytes, and Linode takes 65535 at most\n" if length $user_data > 65535;
    return ( metadata => { user_data => MIME::Base64::encode_base64( $user_data, q{} ) } );
}

# Linode requires one to deploy an image, and scores its strength.
sub _root_pass { return Crypt::PRNG::random_string_from( join( q{}, 'a' .. 'z', 'A' .. 'Z', 0 .. 9, '-_.+=!@%' ), 48 ) }

# Waits until the Linode is in the state wanted, and returns it.
sub _wait_for {
    my ( $self, $id, $name, $want, $timeout ) = @_;

    $timeout //= $BUILD_TIMEOUT;
    my $deadline = time + $timeout;

    while (1) {
        my $linode = $self->_call( 'get-linode-instance', { linodeId => $id } );
        return $linode if ( $linode->{status} // q{} ) eq $want;

        last if time >= $deadline;
        sleep $POLL;
    }

    die "The guest '$name' was not $want ${timeout}s later.\n" . "Check it in the Cloud Manager, and its console through Lish.\n";
}

# Waits until the Linode is in any state but the one it was in.
sub _wait_for_change {
    my ( $self, $id, $name, $from ) = @_;

    my $deadline = time + $BUSY_TIMEOUT;
    while ( time < $deadline ) {
        return 1 if ( $self->_call( 'get-linode-instance', { linodeId => $id } )->{status} // q{} ) ne $from;
        sleep $POLL;
    }

    die "The guest '$name' was still $from ${BUSY_TIMEOUT}s after being asked to change\n";
}

=head2 annihilate_domain($name)

Deletes the guest.  Linode releases its addresses with it.

A volume that was attached to it is detached and kept, because a volume can
hold data that somebody attached it for, and this names each one it leaves.

Returns 0 when there was no such guest, so it is safe to call on a name that is
already gone.  Returns 1 once Linode no longer lists the guest, and dies if it
still does after C<$DELETE_TIMEOUT> seconds.

=cut

sub annihilate_domain {
    my ( $self, $name ) = @_;

    my $linode = $self->linode($name);
    return 0 unless $linode;

    my @volumes = $self->_all( 'get-linode-volumes', { linodeId => $linode->{id} } );

    $self->_call( 'delete-linode-instance', { linodeId => $linode->{id} } );

    # Linode lists a deleted Linode for a while yet, and a caller that asks
    # again in that while is told it exists.
    my $deadline = time + $DELETE_TIMEOUT;
    sleep $POLL while $self->linode($name) && time < $deadline;
    die "The guest '$name' was still listed ${DELETE_TIMEOUT}s after being deleted\n" if $self->linode($name);

    warn "Kept the volume $_->{label} ($_->{id}) that was attached to $name; delete it yourself if nothing needs it\n" for @volumes;

    return 1;
}

=head1 SNAPSHOTS

A snapshot is a private image captured from the guest's disk.  Images belong to
the account, not to a Linode, so the guest a snapshot is of is in its
description, as C<$domain@$snapshot>.  No domain name contains C<@>.

=head2 snapshot_names($domain)

Returns the names of the snapshots of this guest, newest first.

=cut

sub snapshot_names {
    my ( $self, $domain ) = @_;
    return map { substr( $_->{description}, length("$domain\@") ) } $self->_snapshots($domain);
}

sub _snapshots {
    my ( $self, $domain ) = @_;

    return reverse sort { $a->{created} cmp $b->{created} }
      grep { index( $_->{id}, 'private/' ) == 0 && index( $_->{description} // q{}, "$domain\@" ) == 0 } $self->_all('get-images');
}

=head2 create_snapshot($domain, $name, leave_down => $bool)

Captures the guest's disk as a private image, and returns 1.

Linode captures a disk consistently only while nothing writes to it, so this
shuts the guest down, captures the disk, waits until the image is ready, boots
the guest again, and returns once it is running.  With C<leave_down>, it leaves
the guest down, as a rebuild about to happen wants.  C<disk_only> is accepted
and ignored: an image never holds memory.

Warns and returns 0 when Linode will not capture it, after booting the guest
again unless C<leave_down>.  Dies when there is no such guest.

=cut

sub create_snapshot {
    my ( $self, $domain, $name, %opts ) = @_;

    my $linode = $self->linode($domain)
      or die "There is no guest called '$domain' to snapshot\n";

    my $ok = eval {
        my ($disk) = reverse sort { $a->{size} <=> $b->{size} } grep { $_->{filesystem} ne 'swap' } $self->_all( 'get-linode-disks', { linodeId => $linode->{id} } );
        die "$domain has no disk to capture\n" unless $disk;

        $self->_call( 'post-shutdown-linode-instance', { linodeId => $linode->{id} } );
        $self->_wait_for( $linode->{id}, $domain, 'offline' );

        my $image = $self->_call(
            'post-image', {},
            json => {
                disk_id     => $disk->{id},
                label       => $name,
                description => "$domain\@$name",
                tags        => [$MANAGED_BY],
                cloud_init  => Cpanel::JSON::XS::true(),
            }
        );
        $self->_wait_for_image( $image->{id}, $domain );
        1;
    };
    my $error = $@;

    # Up again before this returns, so that what the caller does next is not
    # refused while it boots.
    unless ( $opts{leave_down} ) {
        $self->_call( 'post-boot-linode-instance', { linodeId => $linode->{id} } );
        $self->_wait_for( $linode->{id}, $domain, 'running' );
    }

    return 1 if $ok;
    warn "Could not snapshot $domain: $error";
    return 0;
}

sub _wait_for_image {
    my ( $self, $id, $domain ) = @_;

    my $deadline = time + $IMAGE_TIMEOUT;
    while ( time < $deadline ) {
        return 1 if ( $self->_call( 'get-image', { imageId => $id } )->{status} // q{} ) eq 'available';
        sleep $POLL;
    }

    die "The image of $domain was not ready ${IMAGE_TIMEOUT}s later\n";
}

=head2 revert_snapshot($domain, $name)

Puts the guest back on a snapshot, and returns 1.  This is a rebuild from the
snapshot's image, so the Linode and its addresses stay and its disks are
replaced.

Dies when there is no such guest, or no such snapshot.

=cut

sub revert_snapshot {
    my ( $self, $domain, $name ) = @_;

    my ($image) = grep { $_->{description} eq "$domain\@$name" } $self->_snapshots($domain);
    die "The guest '$domain' has no snapshot called '$name'\n" unless $image;

    $self->rebuild_guest( $domain, image => $image->{id} );
    return 1;
}

=head1 WHAT THIS CANNOT DO

As L<Trog::HV::Cloud/WHAT THIS CANNOT DO>.  There is no console to read over
the API, so F<bin/debug_boot> has nothing to do here: Linode's console is Lish,
which is an ssh login of its own.

=head2 refusals

As L<Trog::HV::Cloud/refusals>, in Linode's terms.

=cut

sub refusals {
    my ($self) = @_;
    return (
        $self->SUPER::refusals,
        define_domain => 'a Linode is not defined from libvirt XML -- use create_guest',
        cloudinit_iso => 'Linode hands cloud-init its user_data through the metadata service, so there is no ISO to build',
        base_image    => 'a root disk is deployed from a Linode image, not a downloaded file',
        create_disk   => 'a Linode gets the disk of its type',
        has_tpm       => 'Linode offers no TPM',
    );
}

=head1 PREFLIGHT

=head2 @names = $hv->preflight_checks(), $hv->preflight_notes()

Return the names of the checks and notes that C<bin/preflight> runs on this
backend, in order.  See L<Trog::HV/PREFLIGHT>.

=cut

sub preflight_checks { return qw{check_reachable check_linode_resources check_linode_budget check_rsync check_transfer_ip check_fetch_sources check_config} }
sub preflight_notes  { return qw{note_stale_image note_apt_mirror note_plaintext_secrets} }

=head2 $result = $hv->check_reachable()

Makes sure that the token in the secret store opens the API.  The other checks
need this to pass.

=cut

sub check_reachable {
    my ($self) = @_;

    my $profile = eval { $self->_call('get-profile') };
    return $self->_verdict( 1, 'Authenticated to ' . $self->describe, q{} ) if $profile;

    return $self->_verdict( 0, 'Could not authenticate to ' . $self->describe, <<"FIX" );
$@
The token is $self->{linode_token} in the secret store.  It needs read_write on
linodes and images, and it may have expired: a personal access token is minted
with an expiry, in the Cloud Manager under API Tokens.
FIX
}

=head2 $result = $hv->check_linode_resources()

Makes sure that the region in F<hypervisors.conf> exists and runs the metadata
service, that Linode sells every type the guests name in C<linode_type>, and that Linode has an image for each distro
the configuration uses, which reads its cloud-init payload from that service.
Without either of the last two a guest boots with no payload, and nothing says
why until the wait for it runs out.

=cut

sub check_linode_resources {
    my ($self) = @_;

    return $self->_verdict( 0, 'Not configured: region', <<'FIX' ) unless $self->region;
The block in hypervisors.conf has to say where to build.  What exists is
Linode's to say:

    linode-cli regions list
FIX

    # A list that could not be had says so, rather than reading as a list
    # without the thing in it.
    my ( %regions, %images );
    my $asked = eval {
        %regions = map { $_->{id} => $_ } $self->_all('get-regions');
        %images  = map { $_->{id} => $_ } $self->_all('get-images');
        1;
    };
    return $self->_verdict( 0, 'Could not ask ' . $self->describe . ' what it has', "$@" ) unless $asked;

    my @types = $self->globals_in_use( $self->size_key );

    my @images = map { $self->image_for_distro($_) } $self->distros_in_use;

    my @wrong;
    push @wrong, "no region '" . $self->region . "'" unless $regions{ $self->region };
    push @wrong, "no type '$_'" for grep {
        !eval { $self->_type($_) }
    } @types;
    push @wrong, 'no metadata service in ' . $self->region
      if $regions{ $self->region } && !any { $_ eq 'Metadata' } @{ $regions{ $self->region }{capabilities} // [] };
    foreach my $image (@images) {
        push @wrong, "no image '$image'" unless $images{$image};
        push @wrong, "$image does not read cloud-init from the metadata service"
          if $images{$image} && !any { $_ eq 'cloud-init' } @{ $images{$image}{capabilities} // [] };
    }

    return $self->_verdict( 1, 'Builds in ' . $self->region . ' from ' . join( ', ', @images ) . ( @types ? ', as ' . join( ', ', @types ) : ', and no guest names a linode_type yet' ), q{} ) unless @wrong;

    return $self->_verdict( 0, 'Linode has ' . join( ', ', @wrong ), <<'FIX' );
A guest gets its cloud-init payload from Linode's metadata service, so it has
to be in a region that runs it, from an image whose capabilities include
cloud-init.  Ask Linode:

    linode-cli regions list --format id,capabilities
    linode-cli images list --format id,capabilities
FIX
}

=head2 $result = $hv->check_linode_budget()

Makes sure the account is inside C<monthly_budget>, and says what a guest of
each type the configuration names would add to it.  Without a budget, it
passes, and says that nothing caps what builds here cost.

=cut

sub check_linode_budget {
    my ($self) = @_;

    my $spend = eval { $self->monthly_spend };
    return $self->_verdict( 0, 'Could not work out what the account costs', "$@" ) unless defined $spend;

    # Per type rather than per guest: what a guest costs is the type it names,
    # and the configuration names as many as its guests do.
    my @each = map { "$_ at " . sprintf( '%.2f', $self->monthly_cost( $self->size_key => $_ ) ) } grep {
        eval { $self->monthly_cost( $self->size_key => $_ ); 1 }
    } $self->globals_in_use( $self->size_key );
    my $now = sprintf( 'The account costs %.2f a month', $spend ) . ( @each ? ', and a guest more: ' . join( ', ', @each ) : q{} );

    return $self->_verdict( 1, "$now; no monthly_budget caps it",                                             q{} ) unless $self->monthly_budget;
    return $self->_verdict( 1, sprintf( '%s, within a monthly_budget of %.2f', $now, $self->monthly_budget ), q{} )
      if $spend < $self->monthly_budget;

    return $self->_verdict( 0, sprintf( '%s, at or over a monthly_budget of %.2f', $now, $self->monthly_budget ), <<'FIX' );
Destroy a guest you have finished with, or raise monthly_budget in the block in
hypervisors.conf.  A guest placed without a pin goes to a machine with room
first, so this only stops the guests that nothing else could take.
FIX
}

=head1 SEE ALSO

L<Trog::HV::Cloud>, which provisions a guest from what this backend's calls
return.

L<Linode::API>, the client.

=cut

1;
