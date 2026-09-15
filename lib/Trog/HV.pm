package Trog::HV;

#ABSTRACT: the hypervisor we are provisioning against, whichever kind it is.

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::Machine';

use Trog::Config();
use Provisioner::Cookbook();

use File::Which();
use List::Util qw{uniq};

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

=item * the guest lifecycle -- C<domain_exists> and C<annihilate_domain> --
and the snapshot four, C<snapshot_names>,
C<snapshot_current_name>, C<create_snapshot> and C<revert_snapshot>.

=item * C<guest_names>, every guest it has, which is what tells an orphan sweep
that a directory belongs to something still running.

=item * C<guest_ssh_ip>, the address a built guest is reached at.

=item * C<clear_guest>, whatever has to go before a guest of that name can be
made.  For libvirt that is the domain, its disks and the addresses it held; a
cloud rebuilds the server it already has, so there is nothing to clear.

=item * C<provision_guest>, the guest itself, from the seed C<bin/provision>
has written.  Returns the address it came up at, which C<guest_ssh_ip> is then
asked how to reach.

=item * C<would_provision>, what the two above would do, for a dry run.

=item * C<prepare_host>, C<release_seed> and C<guest_volumes>: what has to be
done to a hypervisor before it can build, to a guest once cloud-init has read
its seed, and to a guest's disks once it is gone.  A backend with nothing to do
for one says so by doing nothing, which is what lets the scripts above call all
three without asking first which kind of hypervisor they have.

=item * C<builds_by_api> and C<manages_addresses>, which are what F<bin/provision>
and L<Provisioner::IPPool> branch on rather than on a class name.  Only where
the two kinds take genuinely different paths -- a guest defined from XML rather
than asked of a service, an address we allocate rather than one we are given --
and not for a step one of them merely has no use for.  That is what the three
above are for.

=back

Every one of these is declared here, and dies naming the backend and the method
it left out.  So a third backend that forgets one finds out at the call, in
words, rather than as "Can't locate object method" from somewhere in
F<bin/provision>.

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

sub name ($self) { return $self->{name} }

=head2 explicit

Whether this hypervisor was actually asked for, rather than arrived at by
default.  Callers read it as "somebody has already decided, do not place around
them", which is a question worth asking of any backend -- so it lives here even
though only a connection URI can be defaulted.

=cut

sub explicit ($self) { return $self->{explicit} }

=head1 PATHS

=head2 domain_dir

Where the per-domain directories live.  Not a backend's business: it is a
directory on whichever machine is running this, holding what we generated for a
guest, and it means the same thing however that guest gets built.

=cut

sub domain_dir ($self) { return $self->{domain_dir} // $self->default_domain_dir }

=head2 default_domain_dir

Where a domain's directory goes when nothing says otherwise.

A class method, so C<bin/provision> can ask before it has a hypervisor to ask --
it needs the path to find F<provision.conf>, and F<provision.conf> is where the
hypervisor comes from.  Spelling the default there as well is how the two came
to be able to disagree.

=cut

sub default_domain_dir { return '/opt/domains' }

=head1 WHICH WAY A GUEST GETS BUILT

Two questions the scripts above have to ask, which every backend answers
differently and which nothing up there should answer by looking at a class name.

=head2 builds_by_api

Whether a guest is created by asking a service for one, rather than by defining
a domain from the XML L<Provisioner::Recipe::vm> renders.  Which is a different
path through F<bin/provision>, a different set of checks in F<bin/preflight>,
and interfaces whose names nobody here chose.  What it is I<not> for is the
storage pool, the seed ISO and the cdrom: those are L</prepare_host($virtiofs)>,
L</release_seed($domain)> and L</guest_volumes($domain)>, which a service-built guest answers by
having nothing to do.

=head2 manages_addresses

Whether the hypervisor hands its guests the address they are reached at, rather
than us choosing one for them out of F<ipmap.cfg>'s pool.

Where it does, the pool has nothing to allocate, nothing of ours to collide
with, and no reason for L<Provisioner::IPPool> to sweep that hypervisor at all --
the addresses it would find are not drawn from the pool it is protecting.

=cut

sub builds_by_api     { return 0 }
sub manages_addresses { return 0 }

=head1 WHAT EVERY BACKEND ANSWERS

Declared here so that leaving one out is an error that names itself.  See
L</WHAT A BACKEND HAS TO PROVIDE> for what each is for.

=head2 prepare_host($virtiofs)

Whatever the hypervisor needs before a guest can be built on it.  C<$virtiofs>
is our copy of F<virtiofs-better>, for a backend whose guests run in a qemu
process that wants it.

=head2 release_seed($domain)

Called once the guest says cloud-init has finished, and not before: until then
it may still be reading its seed.

=head2 guest_volumes($domain)

The volumes that are this guest's alone and ours to delete once it is gone.
Never the base image, which every other guest is built on.

=cut

# Named, so the message says whose method is missing and that it is owed,
# rather than that some object somewhere could not find it.
sub _abstract {
    my ( $self, $method ) = @_;
    die( ( ref($self) || $self ) . " does not implement $method, which every backend has to\n" );
}

sub build                 ( $self, @ ) { return $self->_abstract('build') }
sub config_keys           ( $self, @ ) { return $self->_abstract('config_keys') }
sub domain_exists         ( $self, @ ) { return $self->_abstract('domain_exists') }
sub annihilate_domain     ( $self, @ ) { return $self->_abstract('annihilate_domain') }
sub guest_names           ( $self, @ ) { return $self->_abstract('guest_names') }
sub guest_ssh_ip          ( $self, @ ) { return $self->_abstract('guest_ssh_ip') }
sub snapshot_names        ( $self, @ ) { return $self->_abstract('snapshot_names') }
sub snapshot_current_name ( $self, @ ) { return $self->_abstract('snapshot_current_name') }
sub create_snapshot       ( $self, @ ) { return $self->_abstract('create_snapshot') }
sub revert_snapshot       ( $self, @ ) { return $self->_abstract('revert_snapshot') }
sub prepare_host          ( $self, @ ) { return $self->_abstract('prepare_host') }
sub release_seed          ( $self, @ ) { return $self->_abstract('release_seed') }
sub guest_volumes         ( $self, @ ) { return $self->_abstract('guest_volumes') }
sub clear_guest           ( $self, @ ) { return $self->_abstract('clear_guest') }
sub provision_guest       ( $self, @ ) { return $self->_abstract('provision_guest') }
sub would_provision       ( $self, @ ) { return $self->_abstract('would_provision') }

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

sub reserve_memory ($self) { return $self->{reserve_memory} // 2048 }
sub reserve_cpus   ($self) { return $self->{reserve_cpus}   // 1 }
sub reserve_disk   ($self) { return $self->{reserve_disk}   // 10 * 1024 * 1024 * 1024 }
sub max_guests     ($self) { return $self->{max_guests}     // 0 }
sub cpu_overcommit ($self) { return $self->{cpu_overcommit} // 4 }

=head2 capacity

What the hypervisor has, and what it has already promised.  Provided by the
backend; L</WHAT A BACKEND HAS TO PROVIDE> lists the keys this expects back.

=cut

sub capacity ( $self, @ ) { return $self->_abstract('capacity') }

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

sub _gb ($bytes) { return int( ( $bytes // 0 ) / ( 1024 * 1024 * 1024 ) ) }

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

=head1 PREFLIGHT

What a hypervisor can be asked about itself, before a guest is built on it.

C<bin/preflight> prints these; it does not know them.  Which questions are worth
asking depends entirely on the backend -- passwordless sudo means nothing to a
cloud, and a Keystone catalogue means nothing to libvirt -- so each one says
which it answers and in what order, and the script walks that list.  It used to
branch on C<builds_by_api> in two places to decide, which is a decision only the
backend can make correctly.

Every check and note returns C<{ ok =E<gt> 1 }>, or C<{ ok =E<gt> 0, what
=E<gt> ..., fix =E<gt> ... }> saying what is wrong and what to do about it.

=head2 @names = $hv->preflight_checks()

The checks this backend answers, in the order they should be asked.  Each names
a method on it.  A failure here means a guest cannot be built.

=head2 @names = $hv->preflight_notes()

The same, for things worth having rather than things required.

=cut

sub preflight_checks ( $self, @ ) { return $self->_abstract('preflight_checks') }
sub preflight_notes  ( $self, @ ) { return $self->_abstract('preflight_notes') }

=head2 $result = $hv->_verdict($ok, $what, $fix)

One check's answer, in the shape C<bin/preflight> prints.

=cut

sub _verdict {
    my ( $self, $ok, $what, $fix ) = @_;
    return { ok => $ok, what => $what, fix => $fix };
}

=head2 $hv->check_reachable(), $hv->check_transfer_ip()

Declared here and answered by the backend, because both questions are real for
either kind and neither has a shared answer.  Reaching a machine is an ssh
login; reaching a cloud is a credential that authenticates and a catalogue with
compute, image and network in it.  Finding the address a guest fetches from
means asking the routing table about a NAT bridge, or reading it out of
F<ipmap.cfg> because a cloud has nothing to ask until the guest exists.

=cut

sub check_reachable   ( $self, @ ) { return $self->_abstract('check_reachable') }
sub check_transfer_ip ( $self, @ ) { return $self->_abstract('check_transfer_ip') }

# Both ends, because both ends run one.  A domain's data directory goes up to the
# hypervisor over rsync and comes off the guest being replaced over rsync, and
# rsync is the only thing in this toolkit that has to exist on the machine
# driving a run as well as on the machine being driven.
#
# Guests are not asked and do not need to be: every one this tool builds installs
# rsync among its base packages, and one that has not been built yet has nothing
# to salvage.
sub check_rsync {
    my ($self) = @_;

    my @missing;
    push( @missing, 'this machine' ) unless File::Which::which('rsync');
    push( @missing, $self->describe ) if !$self->is_local && $self->run_cmd( 'sh', '-c', 'command -v rsync >/dev/null 2>&1' ) != 0;

    return $self->_verdict( 1, 'rsync on both ends', q{} ) unless @missing;

    my $where = join( ' and ', @missing );
    return $self->_verdict( 0, "No rsync on $where", <<"FIX" );
A domain's data directory is shipped to the hypervisor and salvaged off the old
guest with it, and both of those compare before they transfer -- which is what
keeps a re-provision from moving twenty gigabytes of video it already has.

    sudo apt install rsync

on $where.
FIX
}

# A recipe that ships an operator's own files names a directory nothing here
# creates: adminconfig's skel, openvpnclient's cert_dir.  The guest rsyncs those
# out of this machine, so an absent one fails that recipe's target part way
# through a build -- and rsync's error for it names neither the recipe that
# asked nor the domain it was for.
#
# Asked of every domain rather than of one, because preflight is about the
# machine and because skel is usually said once in _base for the whole fleet.
# Read raw, without validating or enriching: a configuration with a CHANGEME
# still in it is one somebody is in the middle of writing, and refusing to look
# at it would withhold exactly the answer they need next.
sub check_fetch_sources {
    my ($self) = @_;

    my $conf = eval { Provisioner::Cookbook->configuration() } // {};
    my %wanted;

    foreach my $domain ( grep { !m/\A_/ } sort keys %$conf ) {
        my $recipes = eval { Provisioner::Cookbook->domain_config( $domain, $conf ) } // {};

        foreach my $name ( sort keys %$recipes ) {
            my $class = eval { Provisioner::Cookbook->load($name) } or next;
            next unless $class->can('fetch_sources');

            my $opts = $recipes->{$name} // {};
            next unless ref $opts eq 'HASH';

            foreach my $path ( eval { $class->fetch_sources(%$opts) } ) {
                next unless defined $path && length $path;
                $wanted{$path}{$name} = 1;
            }
        }
    }

    return $self->_verdict( 1, 'No recipe fetches a directory of yours', q{} ) unless %wanted;

    my @missing = grep { !-d } sort keys %wanted;
    return $self->_verdict( 1, scalar( keys %wanted ) . ' fetched ' . ( keys %wanted == 1 ? 'directory is' : 'directories are' ) . ' here', q{} ) unless @missing;

    my $detail = join( q{}, map { "    $_ (" . join( ', ', sort keys %{ $wanted{$_} } ) . ")\n" } @missing );
    return $self->_verdict( 0, scalar(@missing) . ' fetched ' . ( @missing == 1 ? 'directory is' : 'directories are' ) . ' not on this machine', <<"FIX" );
A guest rsyncs these out of this machine, and the recipe that wants one fails
when it is not there:

$detail
They used to be read off the hypervisor, so on an installation that predates
that change they are still over there.  Bring them here:

    rsync -a @{[ $self->ssh_host // 'the-hypervisor' ]}:<path>/ <path>/
FIX
}

sub check_config {
    my ($self) = @_;

    my $dir = Trog::Config->dir;

    my @missing = grep { !readable("$dir/$_") } qw{ipmap.cfg recipes.yaml};
    return $self->_verdict( 1, "Configuration to copy from: $dir", q{} ) unless @missing;

    return $self->_verdict( 0, "Missing from $dir: " . join( ', ', @missing ), <<"FIX" );
These are where an installation says which machines exist and what every guest
gets.  See Trog::Config for where this directory is and how to point it
somewhere else.
FIX
}

# Not a requirement: nothing here needs it to provision anything, and failing a
# run over its absence would refuse runs that would have worked.  It is the
# difference between guessing at why a guest will not boot and reading its disk,
# so it is worth saying it is missing.
# Is the image guests are built on still the one the distribution would put them
# on?  A note rather than a check: a pin one release behind is a decision
# somebody may well have made on purpose, and a mirror that will not answer is
# no reason to refuse to build anything.
sub note_stale_image {
    my @stale;

    foreach my $name ( Provisioner::Cookbook->distros() ) {
        my $distro = Provisioner::Cookbook->load($name);

        # Undef means the distribution has no way of being asked, or was asked
        # and did not answer.  Either way there is nothing to report.
        my $current = $distro->current_image or next;
        next if $current eq $distro->base_image;

        push( @stale, { name => $name, have => $distro->base_image, want => $current } );
    }

    return { ok => 1 } unless @stale;

    my $fix = join(
        q{},
        map {
            "$_->{name} builds on
  $_->{have}
and the current release is
  $_->{want}
"
        } @stale
    );

    return {
        ok   => 0,
        what => 'A distro recipe is pinned to an image that is no longer current',
        fix  => $fix . <<'FIX' };
Guests already built are unaffected; this is about the next one.  Change the
release in the distro recipe when you want to move, and rebuild -- see
perldoc Provisioner::DistroRecipe.
FIX
}

# Is anything telling guests where to get their packages?
#
# Two things worth saying and they are not the same.  Having built a mirror and
# pointed nothing at it is the more annoying of the two, because the work is
# already done and the fleet is still paying for it every build.
#
# Reads the configuration and nothing else.  In particular it does not ask the
# ip pool whether a named mirror has an address -- that would have a read-only
# command create ips.db, and it is bin/new_config's question to answer anyway.
sub note_apt_mirror {
    my $conf = eval { Provisioner::Cookbook->configuration() } // {};

    my @domains = grep { !m/\A_/ } sort keys %$conf;
    return { ok => 1 } unless @domains;

    my %distro = map { $_ => 1 } Provisioner::Cookbook->distros();
    my ( $pointed, @mirrors );

    foreach my $domain ( @domains, undef ) {
        my $global  = eval { Provisioner::Cookbook->global_config( $domain, $conf ) } // {};
        my $recipes = eval { Provisioner::Cookbook->domain_config( $domain, $conf ) } // {};

        $pointed = 1 if length( $global->{mirror} // q{} );

        foreach my $name ( sort keys %$recipes ) {
            my $opts = $recipes->{$name};
            $pointed = 1 if $distro{$name} && ref $opts eq 'HASH' && length( $opts->{mirror} // q{} );
            push( @mirrors, $domain ) if $name eq 'aptmirror' && defined $domain;
        }
    }

    return { ok => 1 } if $pointed;

    if (@mirrors) {
        my $built = join( ', ', uniq sort @mirrors );
        return { ok => 0, what => "$built mirrors the archive, and nothing points at it", fix => <<"FIX" };
Every guest still fetches every package over the internet on every build, this
one included.  Name it in the _global that the fleet shares:

    _base:
        _global:
            mirror: $built

A bare name is resolved out of the ip pool, because a guest runs cloud-init
before it has DNS.  A mirror somewhere else is named as a URL instead.
FIX
    }

    my ($parent) = map { m/\A[^.]+[.](\N+)\z/ ? $1 : () } @domains;
    my $suggested = 'aptmirror.' . ( $parent // 'example.com' );

    return { ok => 0, what => 'No package mirror is configured', fix => <<"FIX" };
Every guest downloads its packages over the internet on every provision, and
again on every autoupdate.  Across a fleet that is the same few hundred
megabytes per guest per build.

A mirror is a guest like any other:

    bin/new_guest --hostname $suggested aptmirror

and then, once it has synced, point the fleet at it with `mirror:` in _base's
_global.  Nothing depends on that recipe, and a fleet without one builds exactly
as it does now -- only slower.
FIX
}

# Whether a path can be opened for reading, which is all 'is the configuration
# there' amounts to.
sub readable {
    my ($path) = @_;
    open( my $fh, '<', $path ) or return 0;
    close($fh)                 or die "Could not close $path: $!\n";
    return 1;
}

=head1 SEE ALSO

L<Trog::HV::Libvirt>, the backend that builds guests with libvirt.

L<Trog::HV::OpenStack>, the one that asks a cloud.

L<Trog::Machine>, which this is one of.

L<Trog::Hypervisors>, which chooses between several of these.

=cut

1;
