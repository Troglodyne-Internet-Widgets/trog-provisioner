package Trog::Hypervisors;

use strict;
use warnings FATAL => 'all';

use Config::Simple();
use Trog::HV();

=head1 NAME

Trog::Hypervisors - the fleet, and which of them a guest belongs on

=head1 SYNOPSIS

    use Trog::Hypervisors();

    my $fleet = Trog::Hypervisors->load("$domain_dir/hypervisors.conf");

    # Where does this guest already live, or where should it go?
    my $hv = $fleet->select_for('vm.example.com', $config);

=head1 DESCRIPTION

F<provision.conf> describes a I<guest>: how much memory it wants, which packages
go on it, who administers it.  None of that has anything to do with which
machine ends up running it, and a guest definition that names a hypervisor is a
guest definition you cannot move.

So the fleet lives in its own file.  F<hypervisors.conf> is an INI file with one
block per hypervisor, named however you like:

    [hv1]
    libvirt_uri    = qemu+ssh://root@hv1.example.net/system
    bridge_device  = br0
    virbr_device   = virbr0
    pool_path      = /opt/terraform/disks
    reserve_memory = 4096
    reserve_cpus   = 2
    cpu_overcommit = 4
    max_guests     = 20

    [hv2]
    libvirt_uri    = qemu+ssh://root@hv2.example.net/system

Every key but C<libvirt_uri> is optional; see L<Trog::HV> for what they mean and
what they default to.

When the file doesn't exist there is no fleet, everything behaves exactly as it
did before, and the hypervisor is whatever F<provision.conf> or C<--connect>
says -- which for most people is still "this machine".

=head1 CHOOSING

Two questions, in this order.

B<Where does this guest already live?>  Asked of libvirt on each hypervisor in
turn, rather than of a file we wrote down earlier, because the file goes stale
the moment somebody migrates a guest by hand and libvirt never does.  A guest
that already exists somewhere stays there; re-provisioning is not a reason to
move a VM out from under its disks.

B<If it lives nowhere yet, where does it fit?>  Every hypervisor that can hold
it is scored on how comfortable it would be afterwards, and the roomiest wins.
If none can hold it, that is an error naming each hypervisor and what it was
short of -- provisioning a guest onto a machine that cannot run it produces a
worse day than refusing to.

=head1 CLASS METHODS

=head2 load($path)

Read a fleet from F<hypervisors.conf>.  A path that doesn't exist is not an
error: it gives back an empty fleet, which is how "no fleet configured" is
spelled.

=cut

sub load {
    my ($class, $path) = @_;

    my $self = bless { path => $path, order => [], blocks => {} }, $class;
    return $self unless defined $path && -f $path;

    my $config = Config::Simple->new($path)
      or die "Could not read $path: " . Config::Simple->error() . "\n";

    # Config::Simple gives us "block.key" pairs and no way to ask for the block
    # names, so recover them in the order the file lists them.
    my %vars = $config->vars();
    my %seen;
    foreach my $key (sort keys %vars) {
        my ($block) = $key =~ m/\A([^.]+)\./ or next;
        next if $seen{$block}++;
        push @{ $self->{order} }, $block;
        $self->{blocks}{$block} = $config->get_block($block);
    }

    # Config::Simple files anything outside a [block] under 'default', so a
    # file that forgot its headers looks like one hypervisor of that name.
    # Say so rather than provisioning onto a machine nobody meant to name.
    die "$path names no hypervisors; every one needs a [name] header of its own\n"
      if !@{ $self->{order} } || (@{ $self->{order} } == 1 && $self->{order}[0] eq 'default');

    return $self;
}

=head2 default_path($domain_dir)

Where F<hypervisors.conf> lives when nobody said otherwise: beside the domain
directories, since that is the tree an installation already has.

=cut

sub default_path {
    my ($class, $domain_dir) = @_;
    return ($domain_dir // '/opt/domains') . '/hypervisors.conf';
}

=head2 find($domain, %opts)

The hypervisor a guest is on, made current -- for every tool that acts on an
existing guest rather than creating one.  Takes C<uri>, C<hvconf>,
C<domain_dir> and C<config>, all optional.

An explicit C<uri> (i.e. C<--connect>) wins outright.  Failing that, a
configured fleet is searched, and not finding the guest anywhere in it is an
error: acting on a guest we cannot locate would silently do nothing, or worse,
do it to the wrong machine.  With no fleet configured this falls back to
C<Trog::HV::from_config>, which is where the hypervisor used to come from.

=cut

sub find {
    my ($class, $domain, %opts) = @_;

    my %paths = map { $_ => $opts{$_} } grep { defined $opts{$_} } qw{domain_dir};

    return Trog::HV->new(uri => $opts{uri}, %paths) if $opts{uri};

    my $fleet = $class->load($opts{hvconf} // $class->default_path($opts{domain_dir}));
    return Trog::HV->from_config($opts{config}, %paths) unless $fleet->configured;

    my $hv = $fleet->hosting($domain)
      or die "No hypervisor in " . $fleet->{path} . " has a guest called $domain.\n"
      . "Looked on: " . join(', ', $fleet->names) . "\n";

    $hv->activate();
    $hv->{$_} = $paths{$_} for keys %paths;
    return $hv;
}

=head1 METHODS

=head2 configured

Whether there is a fleet at all.  False means every other method here has
nothing to say and the caller should carry on the old way.

=head2 names

The hypervisor names, in the order the file lists them.

=cut

sub configured { return scalar @{ $_[0]->{order} } ? 1 : 0 }
sub names      { return @{ $_[0]->{order} } }

=head2 hypervisor($name)

One hypervisor by name, built but not made current.  Dies if the file doesn't
name it, since a typo in C<hypervisor=> should not silently place a guest
somewhere else.

=cut

sub hypervisor {
    my ($self, $name) = @_;

    my $block = $self->{blocks}{$name}
      or die "No hypervisor named '$name' in " . $self->{path} . "; it has: " . join(', ', $self->names) . "\n";

    return $self->{built}{$name} //= Trog::HV->candidate(
        name     => $name,
        uri      => $block->{libvirt_uri},
            map { $_ => $block->{$_} }
          grep { defined $block->{$_} }
          qw{pool_path domain_dir bridge_device virbr_device
             reserve_memory reserve_cpus reserve_disk max_guests cpu_overcommit},
    );
}

=head2 all

Every hypervisor in the fleet, built but not made current.

=cut

sub all {
    my ($self) = @_;
    return map { $self->hypervisor($_) } $self->names;
}

=head2 hosting($domain)

The hypervisor already running C<$domain>, or undef if none of them is.

A hypervisor we cannot reach is warned about and skipped: it may well be the one
holding the guest, but a fleet that stops working because one machine is down
for maintenance is worse than one that says so and carries on.

=cut

sub hosting {
    my ($self, $domain) = @_;

    foreach my $hv ($self->all) {
        my $has = eval { $hv->domain_exists($domain) };
        unless (defined $has) {
            warn 'Could not ask ' . $hv->name . ' (' . $hv->uri . ") whether it has $domain: $@";
            next;
        }
        return $hv if $has;
    }

    return undef;
}

=head2 place($domain, %needs)

The roomiest hypervisor that can hold a guest wanting C<memory_mb>, C<cpus> and
C<disk_bytes>.  Dies naming every hypervisor and what it was short of when none
can.

=cut

sub place {
    my ($self, $domain, %needs) = @_;

    my (@fits, @why_not);
    foreach my $hv ($self->all) {
        my @reasons = eval { $hv->shortfalls(%needs) };
        if ($@) {
            push @why_not, '  ' . $hv->name . ': unreachable -- ' . _oneline($@);
            next;
        }

        if (@reasons) {
            push @why_not, map { '  ' . $hv->name . ": $_" } @reasons;
            next;
        }

        push @fits, [$hv, $hv->headroom(%needs)];
    }

    die "Nowhere to put $domain: it wants "
      . sprintf("%dMB of memory, %d CPUs and %dGB of disk, and no hypervisor in %s can spare that.\n",
        $needs{memory_mb} // 0, $needs{cpus} // 0,
        ($needs{disk_bytes} // 0) / (1024 * 1024 * 1024), $self->{path})
      . join("\n", @why_not) . "\n"
      unless @fits;

    my ($best) = map { $_->[0] } sort { $b->[1] <=> $a->[1] } @fits;
    printf("Placing %s on %s (%s), the roomiest of %d that fit\n",
        $domain, $best->name, $best->uri, scalar @fits);
    return $best;
}

=head2 select_for($domain, $config)

The hypervisor for a guest, made current: wherever it already lives, else
wherever F<provision.conf> pins it with C<hypervisor=>, else wherever it fits
best.

C<$config> is the guest's F<provision.conf>, or the C<_global> block of its
recipe as a plain hashref -- either way it is read for the C<memory>, C<cpus>
and C<size> the guest asks for, and for a C<hypervisor> pin.

=cut

sub select_for {
    my ($self, $domain, $config) = @_;

    my $existing = $self->hosting($domain);
    if ($existing) {
        print 'Found ' . $domain . ' already on ' . $existing->name . ' (' . $existing->uri . ")\n";
        return $existing->activate();
    }

    my $pinned = _param($config, 'hypervisor');
    if (defined $pinned) {
        my $hv = $self->hypervisor($pinned);
        my @reasons = $hv->shortfalls(_needs($config));
        die "$domain is pinned to $pinned, which cannot take it:\n"
          . join('', map { "  $_\n" } @reasons)
          unless !@reasons;
        return $hv->activate();
    }

    return $self->place($domain, _needs($config))->activate();
}

# What the guest is asking for.  Out of its provision.conf, or out of the
# _global block of its recipe -- the requirements are the same either way, and
# new_config knows them before there is a provision.conf to read them from.
sub _needs {
    my ($config) = @_;
    return (
        memory_mb  => _param($config, 'memory'),
        cpus       => _param($config, 'cpus'),
        disk_bytes => _param($config, 'size'),
    );
}

sub _param {
    my ($config, $key) = @_;
    return undef unless defined $config;

    my $value = ref $config eq 'HASH' ? $config->{$key} : $config->param($key);
    $value = $value->[0] if ref $value eq 'ARRAY';
    return (defined $value && length $value) ? $value : undef;
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
