package Trog::HV;

#ABSTRACT: the hypervisor we are provisioning against, whichever kind it is.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';
use parent 'Trog::Machine';

=head1 NAME

Trog::HV - the hypervisor we are provisioning against, whichever kind it is

=head1 SYNOPSIS

    use Trog::HV();

    my $config = Config::Simple->new('/opt/domains/vm.example.test/provision.conf');
    my $uri    = 'qemu+ssh://root@hv1.example.test/system';    # or undef, from --connect

    # Once, wherever the config and command line are read:
    Trog::HV->from_config($config, uri => $uri);

    # Everywhere else, in any package, without threading it through:
    my $hv = Trog::HV->new();

    $hv->annihilate_domain('vm.example.test');
    print $hv->domain_dir, "\n";

=head1 DESCRIPTION

Everything in this toolkit that used to assume "the hypervisor is this machine"
goes through here, and everything that assumed "the hypervisor runs libvirt"
goes through a backend.

This class is what the rest of the toolkit talks to.  It owns the singleton, the
per-domain directory, and the arithmetic that decides which hypervisor a guest
fits on, none of which depends on what is running the guests.  A backend owns
the rest.

The object is a singleton.  C<< Trog::HV->new() >> with no arguments hands back
whichever hypervisor was configured earlier in the process, so callers do not
have to pass it around.  What comes back is a backend instance, so it answers to
everything here I<and> to everything that backend adds.

=head1 WHAT A BACKEND HAS TO PROVIDE

A backend is a subclass of this class.  It is chosen by L</backend_for(%opts)>,
built by its own C<build>, and has to answer to the following, because this class
and the scripts above it both call them:

=over 4

=item * C<build(%opts)> and C<config_keys>: how one gets made, and which
F<hypervisors.conf> keys make it.

=item * C<is_local> and C<describe>, which every diagnostic prints.

=item * C<capacity>, in the form L</shortfalls(%needs)> and L</headroom(%needs)>
read it: a hash with C<memory_mb>, C<memory_free>, C<memory_committed>, C<cpus>,
C<cpus_allocatable>, C<cpus_committed>, C<cpus_free>, C<disk_free> and
C<guests>.

=item * the guest lifecycle -- C<domain_exists>, C<domain_is_running>,
C<annihilate_domain> -- and the snapshot four, C<snapshot_names>,
C<snapshot_current_name>, C<create_snapshot> and C<revert_snapshot>.

=item * C<guest_names>, every guest it has, which is what tells an orphan sweep
that a directory belongs to something still running.

=item * C<guest_ssh_ip>, the address a built guest is reached at.

=item * C<builds_by_api> and C<manages_addresses>, which are what F<bin/provision>
and L<Provisioner::IPPool> branch on rather than on a class name.

=back

A method that means nothing to a backend should die saying so, rather than
return an undef the caller will carry somewhere else before failing.

=head1 CLASS METHODS

=cut

# The one hypervisor this process is talking to.
my $INSTANCE;

=head2 new(%opts)

Build (or return) the hypervisor.

Called with no meaningful options it returns the instance built earlier in the
process, or a fresh local one if there wasn't any.  Called with options it
builds a new hypervisor and makes I<that> the instance from then on, so the
configuration only has to be read once.

Options: C<uri>, C<pool_path>, C<pool_name>, C<domain_dir>, C<bridge_device>,
C<virbr_device>, C<partition>.  Undefined and empty values are ignored, which
lets callers pass unset command line options straight through.

=cut

sub new {
    my ( $class, %opts ) = @_;

    # Drop the options that weren't actually given, so an unset --connect
    # doesn't look like a request for a different hypervisor.
    my %given = map { $_ => $opts{$_} } grep { defined $opts{$_} && length $opts{$_} } keys %opts;
    return $INSTANCE if $INSTANCE && !%given;

    return $class->candidate(%given)->activate();
}

=head2 candidate(%opts)

Build a hypervisor without making it the current one.

C<new> is a singleton because almost everything wants "the hypervisor we are
working with".  Choosing between several is the exception: L<Trog::Hypervisors>
has to hold them all at once to compare them, and only the winner becomes
current.  Same options as C<new>, plus C<name>.

=head2 activate

Make this hypervisor the one C<new> hands back from here on.  Returns itself,
so it chains.

=cut

sub activate {
    my ($self) = @_;
    $INSTANCE = $self;
    return $self;
}

sub candidate {
    my ( $class, %opts ) = @_;

    my %given = map { $_ => $opts{$_} } grep { defined $opts{$_} && length $opts{$_} } keys %opts;

    # Asked of a backend directly, that is the answer.  Asked of us, pick one.
    my $backend = $class eq __PACKAGE__ ? $class->backend_for(%given) : $class;

    return $backend->build(%given);
}

=head2 backends

Every backend class, loaded.

=cut

sub backends {
    my ($class) = @_;

    my @backends = map { __PACKAGE__ . "::$_" } qw{Libvirt OpenStack};

    # Required rather than used at the top of the file: every backend is a
    # subclass of this class, so loading one from here at compile time is a
    # cycle.
    foreach my $backend (@backends) {
        my $path = $backend =~ s{::}{/}gr;
        require "$path.pm";    ## no critic (Modules::RequireBarewordIncludes)
    }

    return @backends;
}

=head2 backend_for(%opts)

Which backend these options are asking for.

The one seam there is.  Everything else about supporting a second kind of
hypervisor is a subclass; this is the sentence that decides you get one.

=cut

sub backend_for {
    my ( $class, %opts ) = @_;

    # A cloud is named; a libvirt hypervisor is reached at a URI.  Naming both,
    # or neither, is a configuration that cannot be satisfied rather than one to
    # pick a winner from.
    my $named_cloud = defined $opts{cloud} && length $opts{cloud};
    my $named_uri   = defined $opts{uri}   && length $opts{uri};

    die "A hypervisor is either a libvirt_uri or a cloud, and this has both.\n"
      if $named_cloud && $named_uri;

    my $wanted = __PACKAGE__ . ( $named_cloud ? '::OpenStack' : '::Libvirt' );

    my ($backend) = grep { $_ eq $wanted } $class->backends;

    return $backend;
}

=head2 options_from_block($block)

Turn one F<hypervisors.conf> block into constructor options.

Every backend's keys, because which backend a block describes is decided by what
is in it -- so all of them have to be read before that question can be asked.
Each backend says which keys are its own in C<config_keys>; the limits below are
this class's, since placement is.

=cut

my @LIMIT_KEYS = qw{reserve_memory reserve_cpus reserve_disk max_guests cpu_overcommit};

sub options_from_block {
    my ( $class, $block ) = @_;

    my %opts;
    foreach my $backend ( $class->backends ) {
        my %keys = $backend->config_keys;
        foreach my $option ( sort keys %keys ) {
            my $in_file = $keys{$option};
            $opts{$option} = $block->{$in_file} if defined $block->{$in_file};
        }
    }

    $opts{$_} = $block->{$_} for grep { defined $block->{$_} } @LIMIT_KEYS;

    return %opts;
}

=head2 from_config($config, %override)

Build the hypervisor from a L<Config::Simple> object, with anything passed in
C<%override> (i.e. from the command line) winning over what the file says.  A
false C<$config> is fine and means "everything is defaulted".

Reads C<libvirt_uri> for the URI, and C<pool_path>, C<pool_name>,
C<domain_dir>, C<bridge_device>, C<virbr_device> and C<partition> under their
own names.

=cut

# Constructor option => the configuration key it reads.
#
# Every backend's keys, not just one's: which backend a block describes is
# decided by what is in it, so all of them have to be read before that question
# can be asked.
my %CONFIG_KEY = (
    uri => 'libvirt_uri',
    map { $_ => $_ } qw{
      pool_path pool_name domain_dir bridge_device virbr_device partition
      cloud flavor image network floating_network availability_zone security_group keypair
    },
);

sub from_config {
    my ( $class, $config, %override ) = @_;

    my $param = sub {
        my ($key) = @_;
        return undef unless $config;
        my $val = $config->param($key);
        $val = $val->[0] if ref $val eq 'ARRAY';
        return ( defined $val && length $val ) ? $val : undef;
    };

    return $class->new( map { $_ => $override{$_} // $param->( $CONFIG_KEY{$_} ) } keys %CONFIG_KEY );
}

=head2 forget()

Drop the memoized instance.  Only tests should need this.

=cut

sub forget {
    undef $INSTANCE;
    return 1;
}

=head1 IDENTITY

=head2 name

What F<hypervisors.conf> calls this hypervisor, or undef when it didn't come
from there.

=cut

sub name { return $_[0]->{name} }

=head2 explicit

Whether this hypervisor was actually asked for, rather than arrived at by
default.  Callers read it as "somebody has already decided, do not place around
them", which is a question worth asking of any backend -- so it lives here even
though only a connection URI can be defaulted.

=cut

sub explicit { return $_[0]->{explicit} }

=head1 PATHS

=head2 domain_dir

Where the per-domain directories live.  Not a backend's business: it is a
directory on whichever machine is running this, holding what we generated for a
guest, and it means the same thing however that guest gets built.

=cut

sub domain_dir { return $_[0]->{domain_dir} // '/opt/domains' }

=head1 WHICH WAY A GUEST GETS BUILT

Two questions the scripts above have to ask, which every backend answers
differently and which nothing up there should answer by looking at a class name.

=head2 builds_by_api

Whether a guest is created by asking a service for one, rather than by defining
a domain from the XML L<Provisioner::Recipe::vm> renders.  What follows from it
is the storage pool, the seed ISO and the cdrom, none of which a service-built
guest has.

=head2 manages_addresses

Whether the hypervisor hands its guests the address they are reached at, rather
than us choosing one for them out of F<ipmap.cfg>'s pool.

Where it does, the pool has nothing to allocate, nothing of ours to collide
with, and no reason for L<Provisioner::IPPool> to sweep that hypervisor at all --
the addresses it would find are not drawn from the pool it is protecting.

=cut

sub builds_by_api     { return 0 }
sub manages_addresses { return 0 }

=head1 PLACEMENT

Whether one more guest will fit, and which hypervisor it fits on best.

The numbers come from a backend's C<capacity>; the judgement is here, so that
every backend is placed on by the same rules rather than each inventing its own.

=head2 reserve_memory, reserve_cpus, reserve_disk, max_guests, cpu_overcommit

The limits from F<hypervisors.conf>.  C<reserve_memory> is MB to leave for the
host itself, C<reserve_disk> is bytes to leave in the pool, C<max_guests> caps
the domain count (0 means no cap), and C<cpu_overcommit> is how many vCPUs per
physical CPU is considered acceptable.  They default to 2048MB, 1 CPU, 10GB, no
cap, and 4.

=cut

sub reserve_memory { return $_[0]->{reserve_memory} // 2048 }
sub reserve_cpus   { return $_[0]->{reserve_cpus}   // 1 }
sub reserve_disk   { return $_[0]->{reserve_disk}   // 10 * 1024 * 1024 * 1024 }
sub max_guests     { return $_[0]->{max_guests}     // 0 }
sub cpu_overcommit { return $_[0]->{cpu_overcommit} // 4 }

=head2 capacity

What the hypervisor has, and what it has already promised.  Provided by the
backend; L</WHAT A BACKEND HAS TO PROVIDE> lists the keys this expects back.

=cut

sub capacity {
    my ($self) = @_;
    die ref($self) . " does not know how to report its capacity\n";
}

=head2 shortfalls(%needs)

Every reason this hypervisor cannot take a guest wanting C<memory_mb>, C<cpus>
and C<disk_bytes>, in words a person can act on.  An empty list means it fits.

=cut

sub shortfalls {
    my ( $self, %needs ) = @_;

    my $have = $self->capacity;
    my @reasons;

    push @reasons, sprintf(
        'needs %dMB of memory, %dMB free (%dMB physical, %dMB committed, %dMB reserved)',
        $needs{memory_mb},  $have->{memory_free},
        $have->{memory_mb}, $have->{memory_committed}, $self->reserve_memory
    ) if ( $needs{memory_mb} // 0 ) > $have->{memory_free};

    push @reasons, sprintf(
        'needs %d vCPUs, %d free (%d CPUs x%d overcommit, %d committed, %d reserved)',
        $needs{cpus},  $have->{cpus_free},
        $have->{cpus}, $self->cpu_overcommit, $have->{cpus_committed}, $self->reserve_cpus
    ) if ( $needs{cpus} // 0 ) > $have->{cpus_free};

    push @reasons, sprintf(
        'needs %dGB of disk, %dGB free in the pool after a %dGB reserve',
        _gb( $needs{disk_bytes} ), _gb( $have->{disk_free} ), _gb( $self->reserve_disk )
    ) if ( $needs{disk_bytes} // 0 ) > $have->{disk_free};

    push @reasons, sprintf( 'already has %d guests, and max_guests is %d', $have->{guests}, $self->max_guests )
      if $self->max_guests && $have->{guests} >= $self->max_guests;

    return @reasons;
}

sub _gb { return int( ( $_[0] // 0 ) / ( 1024 * 1024 * 1024 ) ) }

=head2 headroom(%needs)

How comfortably this hypervisor would hold the guest, from 0 (exactly full) to
1 (empty), taken as the tightest of the three resources once the guest is on
it.  Placing by the tightest resource is what keeps one hypervisor from filling
its disk while the fleet still has plenty of RAM.

=cut

sub headroom {
    my ( $self, %needs ) = @_;

    my $have = $self->capacity;
    my @fractions;

    push @fractions, _fraction( $have->{memory_free} - ( $needs{memory_mb} // 0 ), $have->{memory_mb} );
    push @fractions, _fraction( $have->{cpus_free} - ( $needs{cpus}        // 0 ), $have->{cpus_allocatable} );
    push @fractions, _fraction( $have->{disk_free} - ( $needs{disk_bytes} // 0 ), $have->{disk_free} + ( $needs{disk_bytes} // 0 ) );

    my ($tightest) = sort { $a <=> $b } @fractions;
    return $tightest;
}

sub _fraction {
    my ( $left, $total ) = @_;
    return 0 if !$total;
    my $fraction = $left / $total;
    return $fraction < 0 ? 0 : $fraction;
}

=head1 SEE ALSO

L<Trog::HV::Libvirt>, the backend that builds guests with libvirt.

L<Trog::HV::OpenStack>, the one that asks a cloud.

L<Trog::Machine>, which this is one of.

L<Trog::Hypervisors>, which chooses between several of these.

=cut

1;
