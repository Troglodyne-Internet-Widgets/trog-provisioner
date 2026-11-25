package Trog::HV::Linode;

#ABSTRACT: the Linode backend: a guest is a Linode, bought by the month.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
no autovivification;
use parent 'Trog::HV::Cloud';

use List::Util qw{any sum0};
use Cpanel::JSON::XS();
use YAML::XS();
use Crypt::PRNG();
use Time::HiRes qw{sleep time};
use Provisioner::Vars();

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
our $RDNS_TIMEOUT   = 600;
our $POLL           = 5;

=head2 config_keys

Returns a list of Str, each F<hypervisors.conf> key that this backend reads,
paired with itself.  C<linode_token> marks a block as one for this backend.

    my %keys = $hv->config_keys;

=head2 marker

Returns Str, C<linode_token>, the option that makes a block a Linode one.  See
L<Trog::HV/backend_for(%opts)>.

    my $marker = $hv->marker;

=head2 size_key

Returns Str, C<linode_type>, the key in the C<_global> of a guest that names
its Linode type.

    my $key = $hv->size_key;

=head2 client_module

Returns a list of two Str: C<Linode::API> and the version of it that this
backend needs, which L<Trog::HV/$module = $hv-E<gt>require_client> loads when a
client is first built.  0.004 is the first release with C<encode_user_data>, which compresses
the cloud-init payload under the 16384 bytes that Linode takes, and the first
that refuses a longer one before it is sent.
0.003 is the first release that has a rule for the C<ip> format, without
which every call of L</$address = $hv-E<gt>set_reverse_dns($domain, $name)> warns.
0.002 is the first that reads a path Linode writes a slash into as a path rather
than as one escaped segment, without which every call about a type is a 404.

    my ( $module, $version ) = $hv->client_module;

=cut

sub config_keys {
    return ( map { $_ => $_ } qw{linode_token region firewall_id private_ip monthly_budget domain_dir} );
}
sub marker        { return 'linode_token' }
sub size_key      { return 'linode_type' }
sub client_module { return ( 'Linode::API', '0.004' ) }

=head2 build(%given)

=over 4

=item given - HashRef - the keys of the block in F<hypervisors.conf>, of which
C<linode_token> is required

=back

Returns a Trog::HV::Linode object.  It does not contact Linode, so a script can
build it to read a path off it without the token.

Dies unless C<linode_token> is a C<secret:> reference.  The token is written
nowhere in the clear, so a literal one is refused rather than used.

    my $hv = Trog::HV::Linode->build( linode_token => 'secret:linode/api/password', region => 'example-region' );

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

Returns Str, a name for the account and region, for a diagnostic message.

    print $hv->describe, "\n";

=head2 uri

Returns Str, the address of the API, so that a message about where a guest is
built has a correct value to show.

    my $endpoint = $hv->uri;

=cut

# The block's value rather than setting's, so that a message never prints what
# a secret: reference resolved to.
sub describe ($self) { return 'Linode' . ( $self->{region} ? " in $self->{region}" : q{} ) }
sub uri              { return $API_URL }

=head2 guest_disks

Returns a list of one Str: C<sd*>.  A guest of Linode names its root disk
C<sda>, and its swap disk C<sdb>.

    my @globs = $hv->guest_disks;

=cut

sub guest_disks { return ('sd*') }

=head2 region, firewall_id, private_ip, monthly_budget

Returns Str or undef, each the value that F<hypervisors.conf> set.  C<region> has no default,
because there is no safe guess at where a guest runs.  C<firewall_id> names a
Cloud Firewall to put a new guest behind, and C<private_ip> gives it an address
on Linode's private network.  C<monthly_budget> is in the currency Linode bills
in.

What a guest boots is not the block's to say: see L</image_for_distro($distro, $release)>.
Neither is what size it is.  A guest names that in its C<_global>, as
C<linode_type>, and one that names none is not built here at all: see
L</shortfalls(%needs)>.

    my $region   = $hv->region;
    my $firewall = $hv->firewall_id;
    my $private  = $hv->private_ip;
    my $budget   = $hv->monthly_budget;

=cut

sub region         ($self) { return $self->setting('region') }
sub firewall_id    ($self) { return $self->setting('firewall_id') }
sub private_ip     ($self) { return $self->setting('private_ip') }
sub monthly_budget ($self) { return $self->setting('monthly_budget') }

=head1 THE API

=head2 api

Returns the L<Linode::API> client, and keeps it for later calls.  It is built
at first use, so an object that never calls Linode never opens the secret
store.  Dies when the client is not installed or the token cannot be read.

    my $api = $hv->api;

=cut

sub api {
    my ($self) = @_;
    return $self->{_api} //= do { $self->require_client; Linode::API->new( token => $self->setting('linode_token') ) };
}

# One call, answered with Linode's JSON.  Dies with what Linode said, or with
# what the specification said was wrong before anything was sent.
#
# Linode refuses an action on a Linode that is still doing the last one, as
# "Linode busy.", and that passes: so it is asked again until $BUSY_TIMEOUT.
my sub call ( $self, $operation, $params = undef, @body ) {
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
my sub every_page ( $self, $operation, $params = {} ) {
    my ( @all, $page, $pages );
    do {
        my $answer = call( $self, $operation, { %$params, page => ++$page, page_size => 500 } );
        push @all, @{ $answer->{data} // [] };
        $pages = $answer->{pages} // 1;
    } while ( $page < $pages );

    return @all;
}

# Every type Linode sells, which does not change within a run.
my sub type_of ( $self, $id ) {
    $self->{_types} //= { map { $_->{id} => $_ } every_page( $self, 'get-linode-types' ) };
    return $self->{_types}{$id} // die "Linode has no type '$id'\n";
}

# The monthly price of a type in a region, or of its backup service.  Linode
# gives 30 of its 75 types an hourly price and no monthly one -- the GPU and
# accelerated ones -- so a month of one of those is $Provisioner::Vars::HOURS_A_MONTH hours of it,
# which is the most it can cost rather than what it will.
my sub price ( $self, $type_id, $region, $addon = undef ) {
    my $type = type_of( $self, $type_id );
    my $item = $addon ? $type->{addons}{$addon} : $type;

    my ($local) = grep { $_->{id} eq $region } @{ $item->{region_prices} // [] };
    my $price = $local // $item->{price} // {};

    return $price->{monthly}                                    if defined $price->{monthly};
    return $price->{hourly} * $Provisioner::Vars::HOURS_A_MONTH if defined $price->{hourly};

    die "Linode reports no price for $type_id" . ( $addon ? " $addon" : q{} ) . " in $region\n";
}

# Every Linode on the account, whatever built it.
my sub linodes ($self) { return every_page( $self, 'get-linode-instances' ) }

=head1 WHAT A GUEST COSTS

=head2 monthly_cost(%needs)

=over 4

=item needs - HashRef - C<linode_type>, the type that the guest names

=back

Returns Num, the monthly price, in this block's region, of the type the guest names in
C<linode_type>.  Linode prices a type differently in some regions, and the
region's price is the one that it bills.

Dies when the guest names no type, when C<region> is not set, or when Linode
has no such type.  L</shortfalls(%needs)> answers for a guest that names none
before anything asks its price.

    my $cost = $hv->monthly_cost( linode_type => 'g6-standard-2' );

=cut

sub monthly_cost {
    my ( $self, %needs ) = @_;

    my $type = $needs{ $self->size_key };
    die 'A guest is built on ' . $self->describe . " as the type it names in linode_type, and this one names none
" unless $type;
    die 'Say which region to build in, in the block for ' . $self->describe . " in hypervisors.conf
" unless $self->region;

    return price( $self, $type, $self->region );
}

=head2 monthly_spend

Returns Num, what every Linode on the account costs a month now, with the backup service
where it is on.  It counts Linodes that something else built too, because the
budget is for the account.  It does not count images, volumes or transfer,
which are small beside the Linodes and billed by use.  Dies when Linode cannot
be asked, or reports no price for a Linode.

    my $spend = $hv->monthly_spend;

=cut

sub monthly_spend {
    my ($self) = @_;

    return sum0 map {
        my $linode = $_;
        price( $self, @{$linode}{qw(type region)} ) + ( $linode->{backups}{enabled} ? price( $self, @{$linode}{qw(type region)}, 'backups' ) : 0 )
    } linodes($self);
}

=head2 image_for_distro($distro, $release)

=over 4

=item distro - Object - the distro recipe, as L<Provisioner::Cookbook> loads it

=item release - Str - the release of the distro, or undef for the one it pins

=back

Returns Str, the Linode image for the distro's distribution and C<$release>, or the release
it pins, which Linode names
by both run together: C<linode/ubuntu24.04>.  Whether Linode has it, and whether
it reads cloud-init, is C<check_linode_resources>'s to find out before a build.

    my $image = $hv->image_for_distro( $distro, 'noble' );

=cut

sub image_for_distro ( $, $distro, $release = undef ) { return 'linode/' . $distro->distribution . $distro->release_version($release) }

=head2 cheapest_for(%needs)

=over 4

=item needs - HashRef - C<memory_mb>, C<cpus> and C<disk_bytes>

=back

Returns HashRef or undef: the cheapest type Linode sells that holds a guest wanting C<memory_mb>,
C<cpus> and C<disk_bytes>, as L<Trog::HV/cheapest_for(%needs)> returns one.

A type that would take the account over C<monthly_budget> is not offered: an
offer that cannot be accepted is noise.

Linode prices 30 of its 75 types by the hour alone, its GPU and accelerated
ones.  Those are offered too, priced at C<$Provisioner::Vars::HOURS_A_MONTH> hours of the hourly
rate, and the offer comes back with C<hourly> as well, so that what is said
about it can say that it is billed by the hour and has no monthly price to be
capped at.  Undef when no type holds the guest,
when the budget leaves room for none, or when Linode cannot be asked.  Dies
when C<monthly_budget> is set and what the account costs cannot be worked out.

    my $offer = $hv->cheapest_for( memory_mb => 2048, cpus => 2, disk_bytes => 20 * 2**30 );

=cut

sub cheapest_for {
    my ( $self, %needs ) = @_;

    my @fit = eval {
        grep { $_->{memory} >= ( $needs{memory_mb} // 0 ) && $_->{vcpus} >= ( $needs{cpus} // 0 ) && $_->{disk} * $Provisioner::Vars::MB >= ( $needs{disk_bytes} // 0 ) } every_page( $self, 'get-linode-types' );
    };
    return undef unless @fit;

    my $room = $self->monthly_budget ? $self->monthly_budget - $self->monthly_spend : undef;

    my @priced =
      sort { $a->{monthly_cost} <=> $b->{monthly_cost} || $a->{memory} <=> $b->{memory} }
      grep { !defined $room                            || $_->{monthly_cost} <= $room }
      map {
        my $type = $_;
        +{ %$type, monthly_cost => eval { price( $self, $type->{id}, $self->region ) } // 0 }
      } @fit;

    return undef unless @priced;

    # A type Linode prices by the hour alone has only a ceiling for a month, so
    # the offer says the hourly rate too.
    my $cheapest = $priced[0];
    my ($local)  = grep { local ($_) = $_; $_->{id} eq $self->region } @{ $cheapest->{region_prices} // [] };
    my $monthly  = defined( ( $local // $cheapest->{price} // {} )->{monthly} );

    return {
        key          => $self->size_key,
        value        => $cheapest->{id},
        monthly_cost => $cheapest->{monthly_cost},
        $monthly ? () : ( hourly => $cheapest->{price}{hourly} ),
    };
}

=head1 CAPACITY

=head2 capacity(%needs)

=over 4

=item needs - HashRef - C<linode_type>, the type that the guest names

=back

Returns HashRef, as L<Trog::HV/capacity(%needs)>, for one guest of the type it names in
C<linode_type>: that type's memory, vCPUs and disk, with nothing committed
against them, because every guest gets a Linode of its own.  C<guests> is the
number of Linodes on the account.

Dies when the guest names no type, which L</shortfalls(%needs)> answers for
first, or when Linode has no such type.

    my $have = $hv->capacity( linode_type => 'g6-standard-2' );

=head2 reserve_memory, reserve_cpus, reserve_disk

Returns 0.  A reserve keeps something back for a host, and there is no host
here to keep it for.

    my $memory = $hv->reserve_memory;
    my $cpus   = $hv->reserve_cpus;
    my $disk   = $hv->reserve_disk;

=cut

sub capacity {
    my ( $self, %needs ) = @_;

    my $named = $needs{ $self->size_key };
    die 'A guest is built on ' . $self->describe . " as the type it names in linode_type, and this one names none
" unless $named;

    my $type = type_of( $self, $named );

    return {
        memory_mb        => $type->{memory},
        memory_committed => 0,
        memory_free      => $type->{memory},
        cpus             => $type->{vcpus},
        cpus_allocatable => $type->{vcpus},
        cpus_committed   => 0,
        cpus_free        => $type->{vcpus},
        disk_free        => $type->{disk} * $Provisioner::Vars::MB,
        guests           => scalar linodes($self),
    };
}

sub reserve_memory { return 0 }
sub reserve_cpus   { return 0 }
sub reserve_disk   { return 0 }

=head2 shortfalls(%needs)

=over 4

=item needs - HashRef - C<linode_type>, C<memory_mb>, C<cpus> and
C<disk_bytes>

=back

As L<Trog::HV/shortfalls(%needs)>, and two more.  A guest that names no
C<linode_type> is not built here at all, which is how a guest is kept off
Linode on purpose.  And a guest that would take what the account costs a month
over C<monthly_budget> does not fit.

Returns a list of Str, one reason for each way that the guest does not fit, or
an empty list when it fits.  Dies as C<monthly_spend> and C<monthly_cost> do
when there is a C<monthly_budget>.

    my @reasons = $hv->shortfalls( linode_type => 'g6-standard-2', memory_mb => 2048 );

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

=head2 server($name)

=over 4

=item name - Str - the label of the Linode

=back

Returns HashRef or undef: the Linode labeled C<$name>, or undef.  Dies when
C<$name> is empty, or when Linode refuses the call.

    my $linode = $hv->server('vm.example.test');

=cut

sub server {
    my ( $self, $name ) = @_;

    die "server() needs a name\n" unless $name;

    my @found = grep { $_->{label} eq $name } every_page( $self, 'get-linode-instances', { 'X-Filter' => Cpanel::JSON::XS::encode_json( { label => $name } ) } );
    return $found[0];
}

=head2 guest_names

Returns a list of Str, the label of every Linode on the account, whatever
built it.  An orphan sweep asks whether anything still uses a name, and one
that somebody else built still does.  Dies when Linode refuses the call.

    my @names = $hv->guest_names;

=cut

sub guest_names ($self) {
    return map { $_->{label} } linodes($self);
}

=head2 guest_ssh_ip($config, $_lease)

=over 4

=item config - Config::Simple|Str - the configuration of the domain, or the
domain name

=item _lease - Any - for libvirt, and this backend ignores it

=back

Returns Str, the public IPv4 address of a guest.

Dies when there is no such guest, or it has no public IPv4 address.

    my $ip = $hv->guest_ssh_ip('vm.example.test');

=cut

sub guest_ssh_ip {
    my ( $self, $config, $_lease ) = @_;

    my $name = ref $config ? $config->param('domain') : $config;

    my $linode = $self->server($name)
      or die "There is no guest called '$name' on " . $self->describe . "\n";

    # A private address routes only inside Linode's own network, and Linode
    # takes them from 192.168.128.0/17.  The rest of RFC 1918 is here for a VPC.
    my ($public) = grep { !m/\A(?:10[.]|192[.]168[.]|172[.](?:1[6-9]|2\d|3[01])[.])/ } @{ $linode->{ipv4} // [] };
    return $public // die "The guest '$name' has no public IPv4 address on " . $self->describe . "\n";
}

=head2 $hv->set_reverse_dns($domain, $name)

=over 4

=item domain - Str - the name of the guest

=item name - Str - the host name for the reverse DNS

=back

Points the reverse DNS of the public IPv4 address of the guest at C<$name>.
The token needs C<ips:read_write>.

Returns Str, the address.

Linode takes C<$name> only when it resolves to the address.  The name can be
one that the build of the guest published a moment ago, which the resolver of
Linode has not seen yet.  So a refusal about C<rdns> is asked again until
C<$RDNS_TIMEOUT>.  Dies with what Linode said after that, or at once on any
other refusal.

    my $address = $hv->set_reverse_dns( 'vm.example.test', 'vm.example.test' );

=cut

sub set_reverse_dns ( $self, $domain, $name ) {
    my $address  = $self->guest_ssh_ip($domain);
    my $deadline = time + $RDNS_TIMEOUT;

    while ( !eval { call( $self, 'put-ip', { address => $address }, json => { rdns => $name } ); 1 } ) {
        die $@ if $@ !~ m/\ALinode[ ]refused[ ]put-ip:[ ]400[ ].*rdns/i || time >= $deadline;
        sleep $POLL;
    }
    return $address;
}

# The payload compressed, which cloud-init uncompresses, because Linode refuses
# one over 16384 bytes after decoding.
my sub metadata ( $self, $user_data ) {
    return () unless $user_data;
    $self->require_client;
    return ( metadata => { user_data => Linode::API->encode_user_data($user_data) } );
}

=head2 $hv->check_user_data($user_data)

=over 4

=item user_data - Str - the cloud-init payload

=back

Dies when Linode would refuse C<$user_data> even compressed, with both of its
sizes and the three largest files of its C<write_files>, which are where to
look for something to take out.  See
L<Trog::HV/$hv-E<gt>check_user_data($user_data)>.

Returns 1 otherwise.

    $hv->check_user_data($cloud_config);

=cut

sub check_user_data {
    my ( $self, $user_data ) = @_;
    return 1 if eval { metadata( $self, $user_data ); 1 };

    # Where in this file encode_user_data was called from, which croak adds.
    my $why = $@ =~ s/[ ]at[ ]\S+[ ]line[ ]\d+[.]?\n?\z/\n/r;

    my $seed  = eval { YAML::XS::Load($user_data) } // {};
    my @files = grep { ref $_ eq 'HASH' } @{ ref $seed->{write_files} eq 'ARRAY' ? $seed->{write_files} : [] };
    my @large = grep { defined } ( reverse sort { $a->[0] <=> $b->[0] } map { [ length( $_->{content} // q{} ), $_->{path} // '(no path)' ] } @files )[ 0 .. 2 ];
    die 'Linode will not take the cloud-init payload of ' . $self->describe . ": $why" . ( @large ? "The largest files that it writes:\n" . join( q{}, map { sprintf "  %6d bytes  %s\n", @$_ } @large ) : q{} );
}

# Linode requires one to deploy an image, and scores its strength.
my sub root_pass { return Crypt::PRNG::random_string_from( join( q{}, 'a' .. 'z', 'A' .. 'Z', 0 .. 9, '-_.+=!@%' ), 48 ) }

# Waits until the Linode is in the state wanted, and returns it.
my sub wait_for ( $self, $id, $name, $want ) {
    my $deadline = time + $BUILD_TIMEOUT;

    while (1) {
        my $linode = call( $self, 'get-linode-instance', { linodeId => $id } );
        return $linode if ( $linode->{status} // q{} ) eq $want;

        last if time >= $deadline;
        sleep $POLL;
    }

    die "The guest '$name' was not $want ${BUILD_TIMEOUT}s later.\n" . "Check it in the Cloud Manager, and its console through Lish.\n";
}

# What every new Linode is made with: its label, region and type, the tag of
# this toolkit, and the firewall and private address of the block.
my sub instance_body ( $self, %spec ) {
    my $name = $spec{name};
    die "Making a guest on " . $self->describe . " needs a name\n" unless $name;
    die "Linode labels are 64 characters at most, and '$name' is longer\n" if length $name > 64;
    die "Building '$name' on " . $self->describe . " needs a size, which the guest names in linode_type\n" unless $spec{size};

    my $region = $spec{region} // $self->region;
    die "Building '$name' on " . $self->describe . " needs 'region'.\nSet it in the block in hypervisors.conf.\n" unless $region;

    my %body = ( label => $name, region => $region, type => $spec{size}, tags => [$MANAGED_BY] );
    $body{firewall_id} = 0 + $self->firewall_id   if $self->firewall_id;
    $body{private_ip}  = Cpanel::JSON::XS::true() if $self->private_ip;
    return %body;
}

=head1 BUILDING AND TEARING DOWN

=head2 create_guest(%spec)

=over 4

=item spec - HashRef - C<name>, C<size>, C<image>, C<region> and C<user_data>,
as below

=back

Builds a guest, and waits until Linode reports it C<running>.

C<name> is required, and is the label.  So is C<size>, the type the guest
names in C<linode_type>, and C<image>, which
L</image_for_distro($distro, $release)> answered when F<bin/new_config> wrote the guest's
F<provision.conf>.  C<region> and C<type> default to the values in
F<hypervisors.conf>.  C<user_data> is the cloud-init payload, which Linode's
metadata service gives to the guest.

The root password is random and kept nowhere.  Every login is by ssh key, and
Linode can reset the password if the console is ever needed.

Returns HashRef, the Linode.

Dies when C<name>, C<region>, C<type> or C<image> has no value, when C<name> is
not a label Linode takes, or when the Linode does not come up in
C<$BUILD_TIMEOUT> seconds.

    my $linode = $hv->create_guest(
        name      => 'vm.example.test',
        size      => 'g6-standard-2',
        image     => 'linode/ubuntu24.04',
        user_data => $cloud_config,
    );

=cut

sub create_guest {
    my ( $self, %spec ) = @_;

    die "Building '" . ( $spec{name} // q{} ) . "' on " . $self->describe . " needs an image, which the distro recipe decides\n" unless $spec{image};
    my %body = instance_body( $self, %spec );

    %body = ( %body, image => $spec{image}, root_pass => root_pass(), booted => Cpanel::JSON::XS::true(), metadata( $self, $spec{user_data} ) );
    my $linode = call( $self, 'post-linode-instance', {}, json => \%body );
    return wait_for( $self, $linode->{id}, $body{label}, 'running' );
}

=head2 reserve_guest(%spec)

=over 4

=item spec - HashRef - C<name>, C<size> and C<region>

=back

Makes a Linode with no image, and so no disk, and waits until Linode reports it
C<offline>.  Linode gives a Linode its addresses when it makes it, so the
address of the guest is known before its configuration is written.
C<bin/new_config> calls this for C<bin/provision>, and C<provision_guest> then
rebuilds the Linode from the image, with the seed.  See
L<Trog::HV/reserve_guest>.

C<name>, C<size> and C<region> are as C<create_guest> takes them.  The Linode
runs nothing until the rebuild, and Linode bills it from now.

Returns 1.  Dies as C<create_guest> does, except over an image.

    $hv->reserve_guest( name => 'vm.example.test', size => 'g6-standard-2' );

=cut

sub reserve_guest {
    my ( $self, %spec ) = @_;

    my %body   = ( instance_body( $self, %spec ), booted => Cpanel::JSON::XS::false() );
    my $linode = call( $self, 'post-linode-instance', {}, json => \%body );
    wait_for( $self, $linode->{id}, $body{label}, 'offline' );
    return 1;
}

=head2 is_reservation($domain)

=over 4

=item domain - Str - the name of the guest

=back

Returns 1 when the Linode of C<$domain> has no disk, as C<reserve_guest> leaves
it, and 0 otherwise.  There is nothing on it to snapshot or to salvage.  Dies
when Linode refuses the call.

    my $empty = $hv->is_reservation('vm.example.test');

=cut

sub is_reservation {
    my ( $self, $domain ) = @_;

    my $linode = $self->server($domain) // return 0;
    my @disks  = every_page( $self, 'get-linode-disks', { linodeId => $linode->{id} } );
    return @disks ? 0 : 1;
}

=head2 rebuild_guest($name, %spec)

=over 4

=item name - Str - the name of the guest

=item spec - HashRef - C<image>, which is required, C<user_data>, the new
cloud-init payload, and C<size>, the type to resize to

=back

Deploys the image again over a guest that exists, with a new cloud-init
payload, and waits until it is C<running> again.  C<image> is required: the
guest's own, from its F<provision.conf>, or a snapshot's.

Linode keeps the Linode and its addresses, and deletes its disks.  When the
guest is not of the type C<size>, the rebuild resizes it to that type.

Returns HashRef, the Linode.

Dies when there is no such guest or no image, or when it does not come back in
C<$BUILD_TIMEOUT> seconds.

    my $linode = $hv->rebuild_guest( 'vm.example.test', image => 'linode/ubuntu24.04', user_data => $cloud_config );

=cut

sub rebuild_guest {
    my ( $self, $name, %spec ) = @_;

    my $linode = $self->server($name)
      or die "There is no guest called '$name' to rebuild\n";

    my $image = $spec{image};
    die "Rebuilding '$name' on " . $self->describe . " needs an image, which the distro recipe decides\n" unless $image;

    my %body = ( image => $image, root_pass => root_pass(), booted => Cpanel::JSON::XS::true(), metadata( $self, $spec{user_data} ) );
    $body{type} = $spec{size} if $spec{size} && $spec{size} ne $linode->{type};

    call( $self, 'post-rebuild-linode-instance', { linodeId => $linode->{id} }, json => \%body );

    # Linode still says running for a moment after it takes the request, so
    # waiting for running alone returns before the rebuild has begun.
    my $deadline = time + $BUSY_TIMEOUT;
    my $changed  = 0;
    while ( !$changed && time < $deadline ) {
        $changed = ( call( $self, 'get-linode-instance', { linodeId => $linode->{id} } )->{status} // q{} ) ne 'running';
        sleep $POLL unless $changed;
    }
    die "The guest '$name' was still running ${BUSY_TIMEOUT}s after being asked to change\n" unless $changed;

    return wait_for( $self, $linode->{id}, $name, 'running' );
}

=head2 annihilate_domain($name)

=over 4

=item name - Str - the name of the guest

=back

Deletes the guest.  Linode releases its addresses with it.

A volume that was attached to it is detached and kept, because a volume can
hold data that somebody attached it for, and this names each one it leaves.

Returns 0 when there was no such guest, so it is safe to call on a name that is
already gone.  Returns 1 once Linode no longer lists the guest, and dies if it
still does after C<$DELETE_TIMEOUT> seconds.

    $hv->annihilate_domain('vm.example.test');

=cut

sub annihilate_domain {
    my ( $self, $name ) = @_;

    my $linode = $self->server($name);
    return 0 unless $linode;

    my @volumes = every_page( $self, 'get-linode-volumes', { linodeId => $linode->{id} } );

    call( $self, 'delete-linode-instance', { linodeId => $linode->{id} } );

    # Linode lists a deleted Linode for a while yet, and a caller that asks
    # again in that while is told it exists.
    my $deadline = time + $DELETE_TIMEOUT;
    sleep $POLL while $self->server($name) && time < $deadline;
    die "The guest '$name' was still listed ${DELETE_TIMEOUT}s after being deleted\n" if $self->server($name);

    warn "Kept the volume $_->{label} ($_->{id}) that was attached to $name; delete it yourself if nothing needs it\n" for @volumes;

    return 1;
}

=head1 SNAPSHOTS

A snapshot is a private image captured from the guest's disk.  Images belong to
the account, not to a Linode, so the guest a snapshot is of is in its
description, as C<$domain@$snapshot>.  No domain name contains C<@>.

=head2 snapshot_names($domain)

=over 4

=item domain - Str - the name of the guest

=back

Returns a list of Str, the names of the snapshots of this guest, newest first.
Dies when Linode refuses the call.

    my @snapshots = $hv->snapshot_names('vm.example.test');

=cut

# The private images whose description says they are of this guest, newest
# first.
my sub snapshots ( $self, $domain ) {
    return reverse sort { $a->{created} cmp $b->{created} }
      grep { index( $_->{id}, 'private/' ) == 0 && index( $_->{description} // q{}, "$domain\@" ) == 0 } every_page( $self, 'get-images' );
}

sub snapshot_names {
    my ( $self, $domain ) = @_;
    return map { substr( $_->{description}, length("$domain\@") ) } snapshots( $self, $domain );
}

=head2 create_snapshot($domain, $name, %opts)

=over 4

=item domain - Str - the name of the guest

=item name - Str - the name of the snapshot

=item opts - HashRef - C<leave_down>, true to leave the guest down, and
C<disk_only>, which is ignored

=back

Captures the guest's disk as a private image.

Returns 1, or 0 when Linode will not capture it.

Linode captures a disk consistently only while nothing writes to it, so this
shuts the guest down, captures the disk, waits until the image is ready, boots
the guest again, and returns once it is running.  With C<leave_down>, it leaves
the guest down, as a rebuild about to happen wants.  C<disk_only> is accepted
and ignored: an image never holds memory.

Warns and returns 0 when Linode will not capture it, after booting the guest
again unless C<leave_down>.  Dies when there is no such guest, or when the
guest does not come back up.

    $hv->create_snapshot( 'vm.example.test', 'before-upgrade' );

=cut

sub create_snapshot {
    my ( $self, $domain, $name, %opts ) = @_;

    my $linode = $self->server($domain)
      or die "There is no guest called '$domain' to snapshot\n";

    my $ok = eval {
        my ($disk) = reverse sort { $a->{size} <=> $b->{size} } grep { $_->{filesystem} ne 'swap' } every_page( $self, 'get-linode-disks', { linodeId => $linode->{id} } );
        die "$domain has no disk to capture\n" unless $disk;

        call( $self, 'post-shutdown-linode-instance', { linodeId => $linode->{id} } );
        wait_for( $self, $linode->{id}, $domain, 'offline' );

        my $image = call(
            $self, 'post-image', {},
            json => {
                disk_id     => $disk->{id},
                label       => $name,
                description => "$domain\@$name",
                tags        => [$MANAGED_BY],
                cloud_init  => Cpanel::JSON::XS::true(),
            }
        );

        my $deadline = time + $IMAGE_TIMEOUT;
        my $ready    = 0;
        while ( !$ready && time < $deadline ) {
            $ready = ( call( $self, 'get-image', { imageId => $image->{id} } )->{status} // q{} ) eq 'available';
            sleep $POLL unless $ready;
        }
        die "The image of $domain was not ready ${IMAGE_TIMEOUT}s later\n" unless $ready;
        1;
    };
    my $error = $@;

    # Up again before this returns, so that what the caller does next is not
    # refused while it boots.
    unless ( $opts{leave_down} ) {
        call( $self, 'post-boot-linode-instance', { linodeId => $linode->{id} } );
        wait_for( $self, $linode->{id}, $domain, 'running' );
    }

    return 1 if $ok;
    warn "Could not snapshot $domain: $error";
    return 0;
}

=head2 revert_snapshot($domain, $name)

=over 4

=item domain - Str - the name of the guest

=item name - Str - the name of the snapshot

=back

Puts the guest back on a snapshot.  This is a rebuild from the snapshot's
image, so the Linode and its addresses stay and its disks are replaced.

Returns 1.

Dies when there is no such guest, or no such snapshot, and as
C<rebuild_guest> does.

    $hv->revert_snapshot( 'vm.example.test', 'before-upgrade' );

=cut

sub revert_snapshot {
    my ( $self, $domain, $name ) = @_;

    my ($image) = grep { $_->{description} eq "$domain\@$name" } snapshots( $self, $domain );
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

Returns a list of Str, each refused method paired with its reason.

    my %reasons = $hv->refusals;

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

=head2 preflight_checks, preflight_notes

Returns a list of Str, the names of the checks and notes that C<bin/preflight>
runs on this backend, in order.  See L<Trog::HV/PREFLIGHT>.

    my @checks = $hv->preflight_checks();
    my @notes  = $hv->preflight_notes();

=cut

sub preflight_checks { return qw{check_client check_reachable check_linode_resources check_linode_budget check_rsync check_sandbox check_gpg check_transfer_ip check_transfer_route check_fetch_sources check_config} }
sub preflight_notes  { return qw{note_stale_image note_apt_mirror note_plaintext_secrets} }

=head2 $hv->check_reachable()

Makes sure that the token in the secret store opens the API.  The other checks
need this to pass.

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_reachable();

=cut

sub check_reachable {
    my ($self) = @_;

    my $profile = eval { call( $self, 'get-profile' ) };
    return $self->verdict( 1, 'Authenticated to ' . $self->describe, q{} ) if $profile;

    return $self->verdict( 0, 'Could not authenticate to ' . $self->describe, <<"FIX" );
$@
The token is $self->{linode_token} in the secret store.  It needs read_write on
linodes, images and ips, and it may have expired: a personal access token is minted
with an expiry, in the Cloud Manager under API Tokens.
FIX
}

=head2 $hv->check_linode_resources()

Makes sure that the region in F<hypervisors.conf> exists and runs the metadata
service, that Linode sells every type the guests name in C<linode_type>, and that Linode has an image for each distro
the configuration uses, which reads its cloud-init payload from that service.
Without either of the last two a guest boots with no payload, and nothing says
why until the wait for it runs out.

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_linode_resources();

=cut

sub check_linode_resources {
    my ($self) = @_;

    return $self->verdict( 0, 'Not configured: region', <<'FIX' ) unless $self->region;
The block in hypervisors.conf has to say where to build.  What exists is
Linode's to say:

    linode-cli regions list
FIX

    # A list that could not be had says so, rather than reading as a list
    # without the thing in it.
    my ( %regions, %images );
    my $asked = eval {
        %regions = map { $_->{id} => $_ } every_page( $self, 'get-regions' );
        %images  = map { $_->{id} => $_ } every_page( $self, 'get-images' );
        1;
    };
    return $self->verdict( 0, 'Could not ask ' . $self->describe . ' what it has', "$@" ) unless $asked;

    my @types = Provisioner::Cookbook->globals_in_use( $self->size_key );

    my @images = map { local ($_) = $_; $self->image_for_distro(@$_) } Provisioner::Cookbook->distros_in_use;

    my @wrong;
    push @wrong, "no region '" . $self->region . "'" unless $regions{ $self->region };
    push @wrong, "no type '$_'" for grep {
        !eval { type_of( $self, $_ ) }
    } @types;
    push @wrong, 'no metadata service in ' . $self->region
      if $regions{ $self->region } && !any { $_ eq 'Metadata' } @{ $regions{ $self->region }{capabilities} // [] };
    foreach my $image (@images) {
        push @wrong, "no image '$image'" unless $images{$image};
        push @wrong, "$image does not read cloud-init from the metadata service"
          if $images{$image} && !any { $_ eq 'cloud-init' } @{ $images{$image}{capabilities} // [] };
    }

    return $self->verdict( 1, 'Builds in ' . $self->region . ' from ' . join( ', ', @images ) . ( @types ? ', as ' . join( ', ', @types ) : ', and no guest names a linode_type yet' ), q{} ) unless @wrong;

    return $self->verdict( 0, 'Linode has ' . join( ', ', @wrong ), <<'FIX' );
A guest gets its cloud-init payload from Linode's metadata service, so it has
to be in a region that runs it, from an image whose capabilities include
cloud-init.  Ask Linode:

    linode-cli regions list --format id,capabilities
    linode-cli images list --format id,capabilities
FIX
}

=head2 $hv->check_linode_budget()

Makes sure the account is inside C<monthly_budget>, and says what a guest of
each type the configuration names would add to it.  Without a budget, it
passes, and says that nothing caps what builds here cost.

Returns HashRef, the answer of C<verdict>.

    my $result = $hv->check_linode_budget();

=cut

sub check_linode_budget {
    my ($self) = @_;

    my $spend = eval { $self->monthly_spend };
    return $self->verdict( 0, 'Could not work out what the account costs', "$@" ) unless defined $spend;

    # Per type rather than per guest: what a guest costs is the type it names,
    # and the configuration names as many as its guests do.
    my @each = map { local ($_) = $_; "$_ at " . sprintf( '%.2f', $self->monthly_cost( $self->size_key => $_ ) ) } grep {
        eval { $self->monthly_cost( $self->size_key => $_ ); 1 }
    } Provisioner::Cookbook->globals_in_use( $self->size_key );
    my $now = sprintf( 'The account costs %.2f a month', $spend ) . ( @each ? ', and a guest more: ' . join( ', ', @each ) : q{} );

    return $self->verdict( 1, "$now; no monthly_budget caps it",                                             q{} ) unless $self->monthly_budget;
    return $self->verdict( 1, sprintf( '%s, within a monthly_budget of %.2f', $now, $self->monthly_budget ), q{} )
      if $spend < $self->monthly_budget;

    return $self->verdict( 0, sprintf( '%s, at or over a monthly_budget of %.2f', $now, $self->monthly_budget ), <<'FIX' );
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
