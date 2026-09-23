package Trog::Hypervisors;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use Config::Simple();
use File::Slurper();
use List::Util qw{any reduce};
use Trog::Config();
use Trog::HV();
use Trog::Local();
use Trog::Utils();
use Provisioner::Cookbook();

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
    bridge_device  = br0
    virbr_device   = virbr0
    pool_path      = /opt/terraform/disks
    pool_name      = tf_disks
    partition      = /machine/hv1
    reserve_memory = 4096
    reserve_cpus   = 2
    cpu_overcommit = 4
    max_guests     = 20

    [hv2]
    libvirt_uri    = qemu+ssh://root@hv2.example.test/system

Each block needs C<libvirt_uri> or C<cloud>, and not both.  Every other key is
optional.  L<Trog::HV> says what each key means and what its default is.

Know two keys before you need them.  C<pool_name> beside C<pool_path> gives a
hypervisor a storage pool of its own.  On a filesystem with a quota, that pool
is the only limit a guest can be held to.  C<partition> puts every guest built
here in one systemd slice.  That slice is the only place to cap CPU and I/O for
all of them together.  Neither key sets a limit by itself.

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

=head2 load($path)

Reads a fleet from F<hypervisors.conf> and returns it.  No fleet is a normal
state.  So when C<$path> is undef, does not exist or cannot be read, this
returns an empty fleet, which means that no fleet is configured.

Dies when a file it can read names no hypervisor.  That includes a file with
keys but no C<[name]> header.

=cut

sub load {
    my ( $class, $path ) = @_;

    my $self = bless { path => $path, order => [], blocks => {} }, $class;
    return $self unless defined $path;

    my $config = eval { Config::Simple->new($path) } or return $self;

    # Config::Simple returns "block.key" pairs in a hash and cannot list the
    # block names, so the order must come from the file itself.
    my %vars = $config->vars();
    my %in_file;
    foreach my $key ( keys %vars ) {
        my ($block) = $key =~ m/\A([^.]+)\./ or next;
        $in_file{$block} = 1;
    }

    my %seen;
    foreach my $block ( _block_order($path), sort keys %in_file ) {
        next unless $in_file{$block};
        next if $seen{$block}++;
        push @{ $self->{order} }, $block;
        $self->{blocks}{$block} = $config->get_block($block);
    }

    # Config::Simple puts any key outside a [block] under 'default', so a file
    # with no headers looks like one hypervisor with that name.
    die "$path names no hypervisors; every one needs a [name] header of its own\n"
      if !@{ $self->{order} } || ( @{ $self->{order} } == 1 && $self->{order}[0] eq 'default' );

    return $self;
}

=head2 _block_order($path)

Returns the names of the C<[block]> headers in C<$path>, in file order, or an
empty list when the file cannot be read.  Config::Simple puts any key outside a
header under C<default>, which has no header line.  So C<load> adds the names
this does not find after these.

=cut

sub _block_order {
    my ($path) = @_;

    my $text = eval { File::Slurper::read_text($path) };
    return () unless defined $text;

    my @order;
    foreach my $line ( split m/\n/, $text ) {
        my ($block) = $line =~ m/\A\s*\[([^\]]+)\]/ or next;
        push @order, $block;
    }

    return @order;
}

=head2 default_path

Returns the path of F<hypervisors.conf> when the caller names no other.  It is
in the configuration directory, with the rest of the configuration of this
installation.  See L<Trog::Config>.

=cut

sub default_path { return Trog::Config->path('hypervisors.conf') }

=head2 find($domain, %opts)

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

=cut

sub find {
    my ( $class, $domain, %opts ) = @_;

    my ( $given, $fleet, %paths ) = $class->_before_fleet(%opts);
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

Returns the hypervisor that a guest is built on, made current.  C<find> is for
a guest that exists, and this is for a guest that is about to be built or
rebuilt.  F<bin/new_config> and F<bin/provision> both call it.  Takes
C<hypervisor>, C<hvconf>, C<domain_dir>, C<config>, C<host> and C<host_config>,
all optional.

A named C<hypervisor> (that is, C<--hypervisor>) wins.  With no fleet
configured, this returns C<< Trog::HV->from_config($config) >>.  Otherwise it
returns what
C<select_for> answers, and it warns if C<config> names a C<libvirt_uri>, which
the fleet overrides.

C<config> is the configuration of the guest, as C<select_for> takes it.  A
domain that goes onto the guest of another domain names that domain as
C<host>, and passes its configuration as C<host_config>.  The fleet then
chooses for the host, because the host is the machine that runs.  A
C<domain_dir> wins over the directory that the fleet names.

=cut

sub choose {
    my ( $class, $domain, %opts ) = @_;

    my ( $given, $fleet, %paths ) = $class->_before_fleet(%opts);
    return $given if $given;

    warn "hypervisors.conf decides which hypervisor $domain lands on; the libvirt_uri in its configuration is ignored\n"
      if defined Trog::HV->config_value( $opts{config}, 'libvirt_uri' );

    my $hv = defined $opts{host} ? $fleet->select_for( $opts{host}, $opts{host_config} ) : $fleet->select_for( $domain, $opts{config} );

    $hv->{$_} = $paths{$_} for keys %paths;
    return $hv;
}

=head2 _before_fleet(%opts)

The steps that C<find> and C<choose> take before they ask a fleet.  Takes their
C<hypervisor>, C<hvconf>, C<domain_dir> and C<config>.  Returns the hypervisor
when a name or the lack of a fleet decides it.  Otherwise returns undef, the
fleet to ask, and the C<domain_dir> pair when one was given.

A name is answered from the fleet, made current, so that a tool told which
hypervisor to use skips the search and the capacity arithmetic both.  It dies
when there is no fleet to name one in, rather than falling back to this
machine, which is not what the name asked for.

=cut

sub _before_fleet {
    my ( $class, %opts ) = @_;

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

=head1 METHODS

=head2 configured

Returns true when there is a fleet.  When it is false, the other methods here
have nothing to say, and the hypervisor comes from F<provision.conf>.

=head2 names

Returns the hypervisor names, in the order of the file.

=cut

sub configured ($self) { return scalar @{ $self->{order} } ? 1 : 0 }
sub names      ($self) { return @{ $self->{order} } }

=head2 hypervisor($name)

Returns one hypervisor by name, built but not made current.  Dies if the file
does not name it, because a typo in C<hypervisor=> must not put a guest
somewhere else.  Also dies if its block has the key of more than one kind of
hypervisor, C<libvirt_uri>, C<cloud> or C<linode_token>, or of none.

=cut

sub hypervisor {
    my ( $self, $name ) = @_;

    my $block = $self->{blocks}{$name}
      or die "No hypervisor named '$name' in " . $self->{path} . "; it has: " . join( ', ', $self->names ) . "\n";

    # A block with no backend's key otherwise gets the default libvirt
    # connection, which is this machine.
    my @markers = map  { $_->marker_key } Trog::HV->backends;
    my @has     = grep { $block->{$_} } @markers;

    die "[$name] in " . $self->{path} . ' has ' . join( ' and ', @has ) . "; it can only be one hypervisor.\n"
      if @has > 1;
    die "[$name] in " . $self->{path} . ' has none of ' . join( ', ', @markers ) . ", so there is nothing to build on.\n"
      unless @has;

    return $self->{built}{$name} //= Trog::HV->candidate(
        name => $name,
        Trog::HV->options_from_block($block),
    );
}

=head2 hypervisors

Returns every hypervisor in the fleet, built but not made current.

=cut

sub hypervisors {
    my ($self) = @_;
    return map { $self->hypervisor($_) } $self->names;
}

=head2 hosting($domain, %opts)

Returns the hypervisor that already runs C<$domain>, or undef when none does.

This warns about a hypervisor it cannot reach, and skips it.  Perhaps that one
holds the guest.  But a fleet that stops when one machine is down for
maintenance is worse than one that warns and continues, when the question is
where to build.

When the question is whether to remove what is left of a guest, that is the
wrong way round, so with C<must_answer> it dies instead, naming each
hypervisor it could not ask, when none of the others has the guest.

=cut

sub hosting {
    my ( $self, $domain, %opts ) = @_;

    my @unasked;
    foreach my $hv ( $self->hypervisors ) {
        my $has = eval { $hv->domain_exists($domain) };
        unless ( defined $has ) {
            my $why = $@;
            warn 'Could not ask ' . $hv->name . ' (' . $hv->uri . ") whether it has $domain: $why";
            push @unasked, $hv->name . ': ' . _oneline($why);
            next;
        }
        return $hv if $has;
    }

    die "Could not ask every hypervisor whether it has $domain, and one of these may:\n" . join( q{}, map { "  $_\n" } @unasked )
      if $opts{must_answer} && @unasked;

    return undef;
}

=head2 place($domain, %needs)

Returns the hypervisor that should hold a guest that wants C<memory_mb>,
C<cpus> and C<disk_bytes>, and prints which one it chose.  Of those that can
hold it, that is the cheapest by L<Trog::HV/monthly_cost(%needs)>, then the
roomiest, then the first in the file.  So a machine we own, which costs
nothing more for one more guest, is chosen over any that bills for it.

When none can hold it, dies with the name of each hypervisor and what it lacks.
A hypervisor that cannot be reached, or cannot say what the guest would cost,
is in that list as unreachable.

=cut

sub place {
    my ( $self, $domain, %needs ) = @_;

    my ( @fits, @why_not );
    foreach my $hv ( $self->hypervisors ) {
        my @reasons = eval { $hv->shortfalls(%needs) };
        if ($@) {
            push @why_not, '  ' . $hv->name . ': unreachable -- ' . _oneline($@);
            next;
        }

        if (@reasons) {
            push @why_not, map { '  ' . $hv->name . ": $_" } @reasons;
            next;
        }

        my $cost = eval { $hv->monthly_cost(%needs) };
        if ( !defined $cost ) {
            push @why_not, '  ' . $hv->name . ': unreachable -- ' . _oneline( $@ || 'it could not say what the guest would cost' );
            next;
        }

        push @fits, [ $hv, $cost, $hv->headroom(%needs) ];
    }

    die "Nowhere to put $domain: it wants " . sprintf(
        "%dMB of memory, %d CPUs and %dGB of disk, and no hypervisor in %s can spare that.\n",
        $needs{memory_mb} // 0,                               $needs{cpus} // 0,
        ( $needs{disk_bytes} // 0 ) / ( 1024 * 1024 * 1024 ), $self->{path}
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

=head2 select_for($domain, $config)

Returns the hypervisor for a guest, made current (see C<find>).  That is the
hypervisor where the guest already lives.  If it lives nowhere, it is the one
that F<provision.conf> pins with C<hypervisor=>.  With no pin, it is the one
where the guest fits best.

C<$config> is the F<provision.conf> of the guest, or the C<_global> block of its
recipe as a plain hashref.  F<bin/new_config> passes the block, because it
knows these values before there is a F<provision.conf>.  Either way, this reads
C<memory>, C<cpus>, C<size> and C<hypervisor> from it.

Dies when the pinned hypervisor is not in the file or cannot take the guest.
Also dies when no hypervisor can take it.  See C<place>.

=cut

sub select_for {
    my ( $self, $domain, $config ) = @_;

    my $existing = $self->hosting($domain);
    if ($existing) {
        print 'Found ' . $domain . ' already on ' . $existing->name . ' (' . $existing->uri . ")\n";
        return $existing->activate();
    }

    my $pinned = Trog::HV->config_value( $config, 'hypervisor' );
    if ( defined $pinned ) {
        my $hv      = $self->hypervisor($pinned);
        my @reasons = $hv->shortfalls( _needs($config) );
        die "$domain is pinned to $pinned, which cannot take it:\n" . join( '', map { "  $_\n" } @reasons )
          if @reasons;
        return $hv->activate();
    }

    my %needs  = _needs($config);
    my $placed = eval { $self->place( $domain, %needs ) };
    return $placed->activate() if $placed;

    # Nowhere has room, which is not the end of it: a hypervisor that sells
    # sizes will sell one that holds this guest, and somebody may say yes.
    return $self->offer( $domain, $config, $@, %needs )->activate();
}

=head2 offer($domain, $config, $why, %needs)

Returns the hypervisor to build C<$domain> on after an operator accepts what it
would sell, having recorded the size in the domain's own file so that the next
run needs no answer.  C<$why> is what C<place> said when nothing fitted.

Every hypervisor that sells sizes is asked for the cheapest that holds the
guest, and the cheapest of those is offered.  With nothing to offer, this dies
with C<$why>, which says what each hypervisor lacked.

A run with nobody to answer does not wait for one.  It dies with the offer
written out: what it would build, what that costs a month, and the line to put
in the guest's C<_global> to accept it.  That covers the reprovision button,
cron and CI, which drive this with no terminal.

=cut

sub offer {
    my ( $self, $domain, $config, $why, %needs ) = @_;

    my @offers =
      sort { $a->{monthly_cost} <=> $b->{monthly_cost} }
      grep { $_ }
      map {
        my $hv    = $_;
        my $offer = eval { $hv->cheapest_for(%needs) };
        $offer ? { %$offer, hv => $hv } : undef
      } $self->hypervisors;

    die $why unless @offers;

    my $best = $offers[0];
    my $line = "$best->{key}: $best->{value}";
    my $what = sprintf( "Nothing in %s has room for %s.\n%s would build it as a %s, at %.2f a month.\n", $self->{path}, $domain, $best->{hv}->name, $best->{value}, $best->{monthly_cost} );

    die $why . "\n" . $what . "To build it there, put this in the _global of $domain:\n\n    $line\n"
      unless Trog::Local->interactive;

    print $what;
    my $answer = Trog::Utils::prompt("Build $domain there? [y/N]:");
    die $why . "\nDeclined, so $domain is not built.\n" unless ( $answer // q{} ) =~ m/\Ay/i;

    my $path = Provisioner::Cookbook->record_global( $domain, $best->{key}, $best->{value} );
    print "Wrote $line to $path, so the next run does not ask.\n";

    # And into what this run is generating from, which was read before the file
    # was written.
    $config->{ $best->{key} } = $best->{value} if ref $config eq 'HASH';

    return $best->{hv};
}

=head2 _needs($config)

Returns what a guest asks for: C<memory_mb>, C<cpus> and C<disk_bytes>, and
the C<size_key> of each backend that has one, such as C<linode_type>.
C<$config> is as for C<select_for>.

=cut

sub _needs {
    my ($config) = @_;

    my %needs = (
        memory_mb  => Trog::HV->config_value( $config, 'memory' ),
        cpus       => Trog::HV->config_value( $config, 'cpus' ),
        disk_bytes => Trog::HV->config_value( $config, 'size' ),
    );

    # And what the guest is on each kind of hypervisor that sells sizes by
    # name, which is how it says which of them it may be built on at all.
    foreach my $backend ( Trog::HV->backends ) {
        my $key = $backend->size_key or next;
        $needs{$key} = Trog::HV->config_value( $config, $key );
    }

    return %needs;
}

sub _oneline {
    my ($message) = @_;
    $message //= '';
    chomp $message;
    $message =~ s/\s*\n\s*/ /g;
    return $message;
}

=head1 SEE ALSO

L<Trog::HV>

=cut

1;
