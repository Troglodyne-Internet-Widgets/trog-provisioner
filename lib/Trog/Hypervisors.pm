package Trog::Hypervisors;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
no autovivification;
use parent 'Trog::Hypervisors::Config';
use List::Util qw{any reduce};
use Config::Simple();
use Socket();
use Trog::Guest();
use Trog::HV();
use Trog::Utils();
use Provisioner::Cookbook();
use Provisioner::Vars();

=head1 NAME

Trog::Hypervisors - the fleet, and which hypervisor a guest belongs on

=head1 SYNOPSIS

    use Trog::Hypervisors();

    my $fleet  = Trog::Hypervisors->load(Trog::Config->path('hypervisors.conf'));
    my $config = Config::Simple->new('/opt/domains/vm.example.test/provision.conf');

    # Where the guest lives now, or where it goes.
    my $hv = $fleet->select_for('vm.example.test', $config);

    # The same, with --hypervisor and no fleet taken care of.
    $hv = Trog::Hypervisors->choose('vm.example.test', config => $config);

=head1 DESCRIPTION

F<provision.conf> describes a I<guest>: how much memory it wants, which packages
go on it, who administers it.  None of that decides which machine runs it.  A
guest definition that names a hypervisor cannot move.

So the fleet has its own file.  F<hypervisors.conf>, in
F</etc/trog-provisioner>, is an INI file with one block per hypervisor.  Give
each block any name you like:

    [hv1]
    libvirt_uri    = qemu+ssh://root@hv1.example.test/system
    dhcp_nics      = virbr0
    static_nics    = br0
    ip_pool_br0    = 192.0.2.64/26
    gateway_br0    = 192.0.2.1
    pool_path      = /opt/terraform/disks
    pool_name      = tf_disks
    partition      = /machine/hv1
    reserve_memory = 4096
    reserve_cpus   = 2
    cpu_overcommit = 4
    max_guests     = 20

    [hv2]
    libvirt_uri    = qemu+ssh://root@hv2.example.test/system

Each block names exactly one kind of hypervisor: C<libvirt_uri>, C<cloud> or
C<linode_token>.  Two of them cannot both be satisfied, and none of them would
fall through to libvirt's default connection, which is this machine -- so a
block with two, or with none, is refused and named.  Every other key is
optional.  L<Trog::HV> says what each key means and what its default is.

C<network> names the network that the guests of a hypervisor are on.  See
L<Trog::HV/network>.

Know two keys before you need them.  C<pool_name> beside C<pool_path> gives a
hypervisor a storage pool of its own.  On a filesystem with a quota, that pool
is the only limit a guest can be held to.  C<partition> puts every guest built
here in one systemd slice.  That slice is the only place to cap CPU and I/O for
all of them together.  Neither key sets a limit by itself.  With a
C<partition>, C<max_guests> and C<cpu_overcommit> are about the guests of the
partition, not about every guest on the hypervisor.  So is C<max_memory>, a
budget of memory that only a partition can have.

If the file does not exist, there is no fleet.  The hypervisor is then whatever
the C<libvirt_uri> of F<provision.conf> names, which for most people is this
machine.  C<--hypervisor> names a block of this file, so it has nothing to name
without one.

=head1 CHOOSING

Two questions, in this order.

B<Where does this guest already live?>  Each hypervisor in turn is asked
whether it runs the guest.  The answer comes from the hypervisor, not from a
file written earlier.  A file goes stale when somebody migrates a guest by hand,
and the hypervisor does not.  A guest that already exists somewhere stays there.
A new provision is not a reason to move a VM away from its disks.

B<If it lives nowhere yet, where does it fit?>  Each hypervisor that can hold
the guest gets a score for the room it has left afterwards, and the roomiest
wins.  If none can hold it, the error names each hypervisor and what it lacks.
A refusal is better than a guest on a machine that cannot run it.

=head1 CLASS METHODS

=cut

# What find and choose share before they ask a fleet: the hypervisor when a
# name or the lack of a fleet decides it, or else undef, the fleet to ask and
# the domain_dir pair.  A name with no fleet dies rather than falling back to
# this machine, which is not what the name asked for.
my sub before_fleet ( $class, %opts ) {
    my %paths = map { $_ => $opts{$_} } grep { defined $opts{$_} } qw{domain_dir};
    my $fleet = $class->load( $opts{hvconf} // $class->default_path );

    if ( defined $opts{hypervisor} ) {
        die "No hypervisors are configured in " . $fleet->{path} . ", so there is no '$opts{hypervisor}' to name.\n"
          unless $fleet->configured;

        my $named = $fleet->hypervisor( $opts{hypervisor} )->activate();
        $named->{$_} = $paths{$_} for keys %paths;
        return $named;
    }

    return Trog::HV->from_config( $opts{config}, %paths ) unless $fleet->configured;

    return ( undef, $fleet, %paths );
}

# How an error names a network, including the one that has no name.
my sub network_name ($network) {
    return $network eq q{} ? 'the network of the hypervisors that name none' : "network '$network'";
}

# Dies when $hv is not on the network that %opts says $domain must be on: a
# guest that is already there, or pinned there, cannot be placed elsewhere.
my sub check_network ( $domain, $hv, %opts ) {
    return 1 if !defined $opts{network} || $hv->network eq $opts{network};
    die "$domain must be on " . network_name( $opts{network} ) . ", because $opts{network_why}.\n" . $hv->name . ' is on ' . network_name( $hv->network ) . ", and $domain is there already or pinned there, so it would not reach it.\n" . "Build it elsewhere, or give it a configuration that needs nothing on the other network.\n";
}

=head2 find($domain, %opts)

=over 4

=item domain - Str - the domain of the guest

=item hypervisor - Str - the name of a hypervisor of the fleet

=item hvconf - Str - the path of F<hypervisors.conf>

=item domain_dir - Str - the directory of the domains, over the one of the hypervisor

=item config - Config::Simple|HashRef - the configuration of the guest, for a hypervisor without a fleet

=item missing_ok - Bool - return undef for a guest that no hypervisor has

=item must_answer - Bool - die when a hypervisor cannot be asked

=back

Returns the hypervisor that runs a guest, made current.  I<Made current> means
that L<Trog::HV/new> returns it from then on.  Every tool that acts on an
existing guest, and does not create one, uses this.  Takes C<hypervisor>,
C<hvconf>, C<domain_dir> and C<config>, all optional, and C<missing_ok> and
C<must_answer>.

A named C<hypervisor> (that is, C<--hypervisor>) wins.  Otherwise this searches
a configured fleet, and dies if no hypervisor in it has the guest.  An action on
a guest that nobody can find does nothing, or acts on the wrong machine.  With
C<missing_ok>, it returns undef there instead, for a caller with something to
do about a guest that is nowhere.  With C<must_answer>, a hypervisor that
cannot be asked is not taken to lack the guest: see L</hosting($domain, %opts)>.
With no fleet configured, this returns C<< Trog::HV->from_config >>.

Returns a Trog::HV, or undef with C<missing_ok>.

    my $hv = Trog::Hypervisors->find( 'vm.test.test', missing_ok => 1 );

=cut

sub find {
    my ( $class, $domain, %opts ) = @_;

    my ( $given, $fleet, %paths ) = before_fleet( $class, %opts );
    return $given if $given;

    my $hv = $fleet->hosting( $domain, must_answer => $opts{must_answer} );
    return undef if !$hv && $opts{missing_ok};
    die "No hypervisor in " . $fleet->{path} . " has a guest called $domain.\n" . "Looked on: " . join( ', ', $fleet->names ) . "\n"
      unless $hv;

    $hv->activate();
    $hv->{$_} = $paths{$_} for keys %paths;
    return $hv;
}

=head2 choose($domain, %opts)

=over 4

=item domain - Str - the domain of the guest

=item hypervisor - Str - the name of a hypervisor of the fleet

=item hvconf - Str - the path of F<hypervisors.conf>

=item domain_dir - Str - the directory of the domains, over the one of the fleet

=item config - Config::Simple|HashRef - the configuration of the guest

=item host - Str - the domain whose guest this domain goes onto

=item host_config - Config::Simple|HashRef - the configuration of that host

=item network - Str - the network that the guest must be on

=item network_why - Str - why, for the errors

=back

Returns the hypervisor that a guest is built on, made current.  C<find> is for
a guest that exists, and this is for a guest that is about to be built or
rebuilt.  F<bin/new_config> and F<bin/provision> both call it.  Takes
C<hypervisor>, C<hvconf>, C<domain_dir>, C<config>, C<host> and C<host_config>,
all optional.

A named C<hypervisor> (that is, C<--hypervisor>) wins, unless C<network> says
the guest must be on another network, and then this dies.  With no fleet
configured, this returns C<< Trog::HV->from_config($config) >>.  Otherwise it
returns what C<select_for> answers, with C<network> and C<network_why>, and it
warns if C<config> names a C<libvirt_uri>, which the fleet overrides.

C<config> is the configuration of the guest, as C<select_for> takes it.  A
domain that goes onto the guest of another domain names that domain as
C<host>, and passes its configuration as C<host_config>.  The fleet then
chooses for the host, because the host is the machine that runs.  A
C<domain_dir> wins over the directory that the fleet names.

Returns a Trog::HV.  Dies when the named hypervisor is not in the fleet or is on
the wrong network, and for each reason that C<select_for> dies.

    my $hv = Trog::Hypervisors->choose( 'vm.test.test', config => $config );

=cut

sub choose {
    my ( $class, $domain, %opts ) = @_;

    my ( $given, $fleet, %paths ) = before_fleet( $class, %opts );
    if ($given) {
        check_network( $domain, $given, %opts );
        return $given;
    }

    warn "hypervisors.conf decides which hypervisor $domain lands on; the libvirt_uri in its configuration is ignored\n"
      if defined Trog::HV->config_value( $opts{config}, 'libvirt_uri' );

    my %network = map { $_ => $opts{$_} } grep { defined $opts{$_} } qw{network network_why};
    my $hv      = defined $opts{host} ? $fleet->select_for( @opts{qw(host host_config)}, %network ) : $fleet->select_for( $domain, $opts{config}, %network );

    $hv->{$_} = $paths{$_} for keys %paths;
    return $hv;
}

=head1 METHODS

=head2 hypervisor($name)

=over 4

=item name - Str - the name of a block of the fleet

=back

Returns one hypervisor by name, built but not made current.  Dies if the file
does not name it, because a typo in C<hypervisor=> must not put a guest
somewhere else.  Also dies if its block has the key of more than one kind of
hypervisor, C<libvirt_uri>, C<cloud> or C<linode_token>, or of none, which
L</$class = $fleet-E<gt>backend_of($name)> is where it finds out.

Returns a Trog::HV.

    my $hv = $fleet->hypervisor('hv1');

=cut

sub hypervisor {
    my ( $self, $name ) = @_;

    $self->backend_of($name);

    return $self->{built}{$name} //= Trog::HV->candidate(
        name => $name,
        Trog::HV->options_from_block( $self->{blocks}{$name} ),
    );
}

=head2 $fleet->backend_of($name)

=over 4

=item name - Str - the name of a block of the fleet

=back

Returns the backend class that a block describes, without building it.  Dies if
the file does not name the block, if the block has the key of more than one kind
of hypervisor, or if it has none of them.  Also dies if it has a key of
L<Trog::HV/replaced_keys>, with what to name instead.

F<bin/preflight> asks this of every block, so a file that cannot be built on is
reported before a run rather than when something reaches that block.  Which is
also why it does not build: a block answers what kind it is without a cloud
being contacted, or its client being installed.

Returns a Str, the name of the class.

    my $class = $fleet->backend_of('hv1');

=cut

sub backend_of {
    my ( $self, $name ) = @_;

    my $block = $self->{blocks}{$name}
      or die "No hypervisor named '$name' in " . $self->{path} . "; it has: " . join( ', ', $self->names ) . "\n";

    # A block with no backend's key otherwise gets the default libvirt
    # connection, which is this machine.
    my @markers = map  { local ($_) = $_; $_->marker_key } Trog::HV->backends;
    my @has     = grep { $block->{$_} } @markers;

    die "[$name] in " . $self->{path} . ' has ' . join( ' and ', @has ) . "; it can only be one hypervisor.\n"
      if @has > 1;
    die "[$name] in " . $self->{path} . ' has none of ' . join( ', ', @markers ) . ", so there is nothing to build on.\n"
      unless @has;

    my %replaced = Trog::HV->replaced_keys($block);
    die "[$name] in " . $self->{path} . ' names ' . join( ', ', map { "$_, which is now $replaced{$_}" } sort keys %replaced ) . ".  See The adapters of a guest in docs/CONFIGURATION.md.\n"
      if %replaced;

    return Trog::HV->backend_for( Trog::HV->options_from_block($block) );
}

=head2 hypervisors

Returns every hypervisor in the fleet, built but not made current.

    my @all = $fleet->hypervisors;

=cut

sub hypervisors {
    my ($self) = @_;
    return map { local ($_) = $_; $self->hypervisor($_) } $self->names;
}

# An error on one line, to go into a list of them.
my sub oneline ($message) {
    $message //= q{};
    chomp $message;
    $message =~ s/\s*\n\s*/ /g;
    return $message;
}

=head2 hosting($domain, %opts)

=over 4

=item domain - Str - the domain of the guest

=item must_answer - Bool - die rather than skip a hypervisor that cannot be asked

=back

Returns the hypervisor that already runs C<$domain>, or undef when none does.

This warns about a hypervisor it cannot reach, and skips it.  Perhaps that one
holds the guest.  But a fleet that stops when one machine is down for
maintenance is worse than one that warns and continues, when the question is
where to build.

When the question is whether to remove what is left of a guest, that is the
wrong way round, so with C<must_answer> it dies instead, naming each
hypervisor it could not ask, when none of the others has the guest.

Returns a Trog::HV, or undef.

    my $hv = $fleet->hosting( 'vm.test.test', must_answer => 1 );

=cut

sub hosting {
    my ( $self, $domain, %opts ) = @_;

    my @unasked;
    foreach my $hv ( $self->hypervisors ) {
        my $has = eval { $hv->domain_exists($domain) };
        unless ( defined $has ) {
            my $why = $@;
            warn 'Could not ask ' . $hv->name . ' (' . $hv->uri . ") whether it has $domain: $why";
            push @unasked, $hv->name . ': ' . oneline($why);
            next;
        }
        return $hv if $has;
    }

    die "Could not ask every hypervisor whether it has $domain, and one of these may:\n" . join( q{}, map { "  $_\n" } @unasked )
      if $opts{must_answer} && @unasked;

    return undef;
}

# A L<Trog::Guest> for the guest of C<$domain> that is up, as its admin user,
# with its key from the store.  A class method: it loads the fleet that
# C<default_path> names.  Without a fleet, it asks the hypervisor that
# L<Trog::HV/new> returns.
#
# The guest of a domain in C<_shared> is the guest of its host, which
# L<Provisioner::Cookbook/host_of> names.
#
# It takes the options of C<locate_guest>.
# @param   domain  Str  the domain of the guest
# @param   %opts   Str  each option of C<locate_guest>, by its name
# @returns Trog::Guest|Undef  the guest, or undef when no hypervisor runs it
# @throws  when there is no key for the guest.  The store holds the key, and a
#   program with nobody at its terminal cannot ask for the password of the store,
#   so the message says to give it on standard input, or to log in through the
#   ssh agent with C<guest_of_with_agent>.
# @example my $guest = Trog::Hypervisors->guest_of('vm.test.test') or die "Not up\n";
sub guest_of {
    my ( $class, $domain, %opts ) = @_;

    my $where = $class->locate_guest( $domain, %opts ) or return;
    my $key   = Trog::Guest->key_path( $where->{name}, "$where->{dir}/key.rsa" )
      or die "No key for $where->{name}, in the store or at $where->{dir}/key.rsa.\n" . "If it is in the store, the password goes on stdin, as for bin/provision.\n" . "If its admin trusts a key in your ssh agent, log in with the agent instead, as ask_guest --agent does.\n";

    return Trog::Guest->new( %{$where}{qw{name host user}}, key_path => $key );
}

# As C<guest_of>, but the guest logs in with the keys of the ssh agent in
# C<SSH_AUTH_SOCK>, and never asks for the key of the guest.  So it never opens
# the store for that key.  The admin of a guest trusts the keys of
# F<admin_authorized_keys>, so an operator whose key is there needs no store to
# reach the guest.  Finding a guest on a hypervisor that needs a token, such as a
# cloud, still opens the store for that token.
# @param   domain  Str  the domain of the guest
# @param   %opts   Str  each option of C<locate_guest>, by its name
# @returns Trog::Guest|Undef  the guest, or undef when no hypervisor runs it
# @throws  when C<SSH_AUTH_SOCK> is not set
# @example my $guest = Trog::Hypervisors->guest_of_with_agent( 'vm.test.test', fall_back_to_name => 1 );
sub guest_of_with_agent {
    my ( $class, $domain, %opts ) = @_;

    die "SSH_AUTH_SOCK is not set, so there is no ssh agent to log in to $domain with.\n" unless $ENV{SSH_AUTH_SOCK};
    my $where = $class->locate_guest( $domain, %opts ) or return;

    return Trog::Guest->new( %{$where}{qw{name host user}} );
}

# Where the guest of C<$domain> is, for C<guest_of> and C<guest_of_with_agent>.
#
# The guest of a domain in C<_shared> is the guest of its host, which
# L<Provisioner::Cookbook/host_of> names.  The admin user comes from the
# F<provision.conf> of the guest, and is C<root> without one.  The address is the
# guest itself, also for a domain behind a relay, whose public names reach the
# relay.  Without a hypervisor that has the guest, the directory is under
# L<Trog::HV/default_domain_dir>.
#
# With C<fall_back_to_name>, when no hypervisor says an address for the guest,
# because none has it or because the one that might could not be asked, the
# address is the one that the name of the machine resolves to, as for
# C<ssh $machine>.  It warns that it did so, and why.  It returns undef only
# when the name does not resolve either.  A hypervisor that dies when it is asked
# for the address is then a warning, not an error.
#
# This is for an operator who asks a guest a question, such as C<ask_guest> and
# C<collect_artifacts>.  A hypervisor that wants a token from the store cannot be
# asked with nobody at the terminal, and C<--agent> wants no store at all.  It is
# off by default, because the other callers take undef to mean that the guest is
# not up: C<bin/destroy> then skips the guest, and must not run a command as root
# on whatever machine a stale name still reaches.  The name can also reach a
# relay in front of the guest, and not the guest.
# @param   domain             Str  the domain of the guest
# @param   fall_back_to_name  Bool  resolve the name of the machine when no
#   hypervisor says its address
# @param   host               Str  the address of the guest, so that nobody is
#   asked for one.  The hypervisor is still found, for the directory of the guest.
# @param   hypervisor         Str  the name of the hypervisor of the fleet to ask,
#   rather than whichever has the guest
# @param   hvconf             Str  the file of the fleet, rather than C<default_path>
# @returns HashRef|Undef  C<name>, the machine, C<host>, its address, C<user>, its
#   admin user, and C<dir>, the directory of its configuration; or undef when no
#   hypervisor runs it at an address
# @throws  when the hypervisor dies as it is asked for the address, without
#   C<fall_back_to_name>
# @throws  when the named C<hypervisor> is not in the fleet
# @example my $where = Trog::Hypervisors->locate_guest( 'vm.test.test', fall_back_to_name => 1 );
sub locate_guest {
    my ( $class, $domain, %opts ) = @_;

    my $machine = Provisioner::Cookbook->machine_of($domain);

    my $fleet = $class->load( $opts{hvconf} // $class->default_path() );
    my $hv =
        defined $opts{hypervisor} ? $fleet->hypervisor( $opts{hypervisor} )->activate()
      : $fleet->configured        ? $fleet->hosting($machine)
      :                             Trog::HV->new();

    my $host = $opts{host};
    if ( !defined $host && $hv ) {
        $host = eval { $hv->inspection_address($machine) };
        if ( my $why = $@ ) {
            die $why unless $opts{fall_back_to_name};
            warn 'Could not ask ' . $hv->describe . " where $machine is: $why";
        }
    }
    if ( !$host && $opts{fall_back_to_name} ) {

        # The first address that getaddrinfo gives is the one ssh tries first.
        my ( $unresolved, $found ) = Socket::getaddrinfo( $machine, undef, { socktype => Socket::SOCK_STREAM() } );
        return if $unresolved || !$found;
        ( my $unnamed, $host ) = Socket::getnameinfo( $found->{addr}, Socket::NI_NUMERICHOST(), Socket::NIx_NOSERV() );
        return if $unnamed;
        warn "No hypervisor said where $machine is, but $machine resolves to $host, so it is reached there.\n";
    }
    return unless $host;

    # Config::Simple reads into $_ without a local of its own, and a caller
    # can be inside a map.  Trog::Hypervisors::Config has the same guard.
    local $_;
    my $dir    = ( $hv ? $hv->domain_dir : Trog::HV->default_domain_dir ) . "/$machine";
    my $config = eval { Config::Simple->new("$dir/provision.conf") };

    return { name => $machine, host => $host, user => ( $config ? $config->param('admin_user') : undef ) // 'root', dir => $dir };
}

=head2 place($domain, %needs)

=over 4

=item domain - Str - the domain of the guest

=item memory_mb - Int - the memory that it wants

=item cpus - Int - the CPUs that it wants

=item disk_bytes - Int - the disk that it wants

=item network - Str - the network that the guest must be on

=item network_why - Str - why, for the errors

=back

Returns the hypervisor that should hold a guest that wants C<memory_mb>,
C<cpus> and C<disk_bytes>, and prints which one it chose.  Of those that can
hold it, that is the cheapest by L<Trog::HV/monthly_cost(%needs)>, then the
roomiest, then the first in the file.  So a machine we own, which costs
nothing more for one more guest, is chosen over any that bills for it.

When none can hold it, dies with the name of each hypervisor and what it lacks.
A hypervisor that cannot be reached, or cannot say what the guest would cost,
is in that list as unreachable.

Returns a Trog::HV.

    my $hv = $fleet->place( 'vm.test.test', memory_mb => 2048, cpus => 2, disk_bytes => 20 * 2**30 );

=cut

sub place {
    my ( $self, $domain, %needs ) = @_;

    my ( $network, $network_why ) = delete @needs{qw{network network_why}};
    my ( @fits, @why_not );
    foreach my $hv ( $self->hypervisors ) {
        if ( defined $network && $hv->network ne $network ) {
            push @why_not, '  ' . $hv->name . ': ' . network_name( $hv->network ) . ", and $domain must be on " . network_name($network) . ", because $network_why";
            next;
        }

        my @reasons = eval { $hv->shortfalls(%needs) };
        if ($@) {
            push @why_not, '  ' . $hv->name . ': unreachable -- ' . oneline($@);
            next;
        }

        if (@reasons) {
            push @why_not, map { local ($_) = $_; '  ' . $hv->name . ": $_" } @reasons;
            next;
        }

        my $cost = eval { $hv->monthly_cost(%needs) };
        if ( !defined $cost ) {
            push @why_not, '  ' . $hv->name . ': unreachable -- ' . oneline( $@ || 'it could not say what the guest would cost' );
            next;
        }

        push @fits, [ $hv, $cost, $hv->headroom(%needs) ];
    }

    die "Nowhere to put $domain: it wants " . sprintf(
        "%dMB of memory, %d CPUs and %dGB of disk, and no hypervisor in %s can spare that.\n",
        $needs{memory_mb} // 0,                               $needs{cpus} // 0,
        ( $needs{disk_bytes} // 0 ) / $Provisioner::Vars::GB, $self->{path}
      )
      . join( "\n", @why_not ) . "\n"
      unless @fits;

    # The cheapest, of those the roomiest, and of those the first in the file.
    my $winner = reduce { ( $b->[1] < $a->[1] || ( $b->[1] == $a->[1] && $b->[2] > $a->[2] ) ) ? $b : $a } @fits;
    my ( $best, $cost ) = @$winner;
    my $why =
        $cost                     ? sprintf( 'the cheapest at %.2f a month', $cost )
      : ( any { $_->[1] } @fits ) ? 'the roomiest of those that cost nothing more'
      :                             'the roomiest';
    printf( "Placing %s on %s (%s), %s of %d that fit\n", $domain, $best->name, $best->uri, $why, scalar @fits );
    return $best;
}

# What a guest asks for: memory_mb, cpus and disk_bytes, the distro and release
# it boots, and the size_key of each backend that has one.  $config is as for
# select_for.
my sub needs ($config) {
    my %needs = (
        memory_mb  => Trog::HV->config_value( $config, 'memory' ),
        cpus       => Trog::HV->config_value( $config, 'cpus' ),
        disk_bytes => Trog::HV->config_value( $config, 'size' ),

        # What it boots, because what a hypervisor has to hold is the image of
        # that distribution rather than the guest's own figures alone.
        distro  => Trog::HV->config_value( $config, 'distro' ) // 'ubuntu',
        release => Trog::HV->config_value( $config, 'release' ),
    );

    # And what the guest is on each kind of hypervisor that sells sizes by
    # name, which is how it says which of them it may be built on at all.
    foreach my $backend ( Trog::HV->backends ) {
        my $key = $backend->size_key or next;
        $needs{$key} = Trog::HV->config_value( $config, $key );
    }

    return %needs;
}

=head2 select_for($domain, $config, %opts)

=over 4

=item domain - Str - the domain of the guest

=item config - Config::Simple|HashRef - the F<provision.conf> of the guest, or the C<_global> block of its recipe

=item network - Str - the network that the guest must be on

=item network_why - Str - why, for the errors

=back

Returns the hypervisor for a guest, made current (see C<find>).  That is the
hypervisor where the guest already lives.  If it lives nowhere, it is the one
that F<provision.conf> pins with C<hypervisor=>.  With no pin, it is the one
where the guest fits best.

C<network> in C<%opts> is the network that the guest must be on, see
L<Trog::HV/network>, and C<network_why> says why, for the errors.  Placement
then takes only a hypervisor on that network.  A guest that already lives on
another network, or is pinned to one, is refused, because it cannot move.

C<$config> is the F<provision.conf> of the guest, or the C<_global> block of its
recipe as a plain hashref.  F<bin/new_config> passes the block, because it
knows these values before there is a F<provision.conf>.  Either way, this reads
C<memory>, C<cpus>, C<size> and C<hypervisor> from it.

Dies when the pinned hypervisor is not in the file or cannot take the guest.
Also dies when no hypervisor can take it.  See C<place>.  C<place> and C<offer>
also take C<network> and C<network_why> among the needs, and consider only the
hypervisors on that network.

Returns a Trog::HV.

    my $hv = $fleet->select_for( 'vm.test.test', $config );

=cut

sub select_for {
    my ( $self, $domain, $config, %opts ) = @_;

    my $existing = $self->hosting($domain);
    if ($existing) {
        print 'Found ' . $domain . ' already on ' . $existing->name . ' (' . $existing->uri . ")\n";
        check_network( $domain, $existing, %opts );
        return $existing->activate();
    }

    my $pinned = Trog::HV->config_value( $config, 'hypervisor' );
    if ( defined $pinned ) {
        my $hv      = $self->hypervisor($pinned);
        my @reasons = $hv->shortfalls( needs($config) );
        die "$domain is pinned to $pinned, which cannot take it:\n" . join( '', map { "  $_\n" } @reasons )
          if @reasons;
        check_network( $domain, $hv, %opts );
        return $hv->activate();
    }

    my %needs  = ( needs($config), ( defined $opts{network} ? ( network => $opts{network}, network_why => $opts{network_why} ) : () ) );
    my $placed = eval { $self->place( $domain, %needs ) };
    return $placed->activate() if $placed;

    # Nowhere has room, which is not the end of it: a hypervisor that sells
    # sizes will sell one that holds this guest, and somebody may say yes.
    return $self->offer( $domain, $config, $@, %needs )->activate();
}

=head2 offer($domain, $config, $why, %needs)

=over 4

=item domain - Str - the domain of the guest

=item config - Config::Simple|HashRef - the configuration of the guest

=item why - Str - what C<place> said when nothing fitted

=item %needs - what the guest wants, as C<place> takes it

=back

Returns the hypervisor to build C<$domain> on after an operator accepts what it
would sell, having recorded the size in the domain's own file so that the next
run needs no answer.  C<$why> is what C<place> said when nothing fitted.

Every hypervisor that sells sizes is asked for the cheapest that holds the
guest, and the cheapest of those is offered.  With nothing to offer, this dies
with C<$why>, which says what each hypervisor lacked.

A run with nobody to answer does not wait for one.  It dies with the offer
written out: what it would build, what that costs a month, and the line to put
in the guest's C<_global> to accept it.  A hypervisor that bills by the hour
says so, and what the rate is, because the monthly figure for one of those is
hours of it rather than a price that caps anything.  That covers the reprovision button,
cron and CI, which drive this with no terminal.

Returns a Trog::HV.  Dies when the operator declines, when the hypervisor then
refuses what it offered, and as said above.

    my $hv = $fleet->offer( 'vm.test.test', $config, $why, memory_mb => 2048 );

=cut

sub offer {
    my ( $self, $domain, $config, $why, %needs ) = @_;

    my ( $network, undef ) = delete @needs{qw{network network_why}};
    my @offers =
      sort { $a->{monthly_cost} <=> $b->{monthly_cost} }
      grep { $_ }
      map {
        my $hv    = $_;
        my $offer = eval { $hv->cheapest_for(%needs) };
        $offer ? { %$offer, hv => $hv } : undef
      } grep { local ($_) = $_; !defined $network || $_->network eq $network } $self->hypervisors;

    die $why unless @offers;

    my $best = $offers[0];
    my $line = "$best->{key}: $best->{value}";
    my $rate = $best->{hourly} ? sprintf( ', billed at %s an hour, with no monthly price to cap it', $best->{hourly} ) : q{};
    my $what = sprintf( "Nothing in %s has room for %s.\n%s would build it as a %s, at %.2f a month%s.\n", $self->{path}, $domain, $best->{hv}->name, @{$best}{qw(value monthly_cost)}, $rate );

    die $why . "\n" . $what . "To build it there, put this in the _global of $domain:\n\n    $line\n"
      unless Trog::Utils::interactive();

    print $what;
    my $answer = Trog::Utils::prompt("Build $domain there? [y/N]:");
    die $why . "\nDeclined, so $domain is not built.\n" unless ( $answer // q{} ) =~ m/\Ay/i;

    # What was offered has to be what fits: a backend that offered something
    # its own limits refuse would otherwise be built on, and refuse at the API.
    my @still = $best->{hv}->shortfalls( %needs, $best->{key} => $best->{value} );
    die $why . "\n" . $best->{hv}->name . " offered a $best->{value}, and then would not take it:\n" . join( q{}, map { "  $_\n" } @still )
      if @still;

    my $path = Provisioner::Cookbook->record_global( $domain, @{$best}{qw(key value)} );
    print "Wrote $line to $path, so the next run does not ask.\n";

    # And into what this run is generating from, which was read before the file
    # was written.
    $config->{ $best->{key} } = $best->{value} if ref $config eq 'HASH';

    return $best->{hv};
}

=head1 SEE ALSO

L<Trog::HV>, and L<Trog::Hypervisors::Config>, which reads the file: C<load>,
C<default_path>, C<configured>, C<names> and C<secret_references> are its.

=cut

1;
