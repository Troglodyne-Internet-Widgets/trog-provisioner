package Trog::HV;

use strict;
use warnings FATAL => 'all';

use Fcntl();
use File::Path();
use File::Copy();
use File::Slurper();
use Sys::Virt();
use URI();
use URI::Split();
use Net::OpenSSH::More();

=head1 NAME

Trog::HV - the hypervisor we are provisioning against

=head1 SYNOPSIS

    use Trog::HV();

    # Once, wherever the config and command line are read:
    my $hv = Trog::HV->from_config($config, uri => $connect_option);

    # Everywhere else, in any package, without threading it through:
    my $hv = Trog::HV->new();

    $hv->annihilate_domain('vm.example.com');
    $hv->write_text_hv('/etc/rsyslog.d/10-vm.conf', $conf, sudo => 1);
    print $hv->tf_config_dir, "\n";

=head1 DESCRIPTION

Everything in this toolkit that used to assume "the hypervisor is this machine"
goes through here instead:

=over 4

=item * libvirt itself, via L<Sys::Virt>, which speaks every transport a
connection URI can name and needs no shell to do it.

=item * shell commands that have to run I<on> the HV (brctl, ip, sshd_config,
the libvirt lease helper).

=item * files that have to live I<on> the HV (the storage pool dir,
virtiofs-better, rsyslog drop-ins, the domain directory the guest pulls its
payload from).

=item * the paths those things live at, and the HV-derived facts (bridge
device, internal IP, sshd port) the templates need.

=back

When no URI is configured we are the hypervisor, and every one of those degrades
to exactly what the code did before: libvirt's own default connection and plain
C<system>/C<File::*> against the local filesystem.

The object is a singleton.  C<< Trog::HV->new() >> with no arguments hands back
whichever hypervisor was configured earlier in the process, so callers do not
have to pass it around or keep their own copy.

=head1 CLASS METHODS

=cut

our $DEFAULT_URI = 'qemu:///system';

# Transports over which we can also get a shell on the HV.
my %SSH_TRANSPORT = map { $_ => 1 } qw{ssh libssh libssh2};

# The one hypervisor this process is talking to.
my $INSTANCE;

=head2 new(%opts)

Build (or return) the hypervisor.

Called with no meaningful options it returns the instance built earlier in the
process, or a fresh local one if there wasn't any.  Called with options it
builds a new hypervisor and makes I<that> the instance from then on, so the
configuration only has to be read once.

Options: C<uri>, C<tf_dir>, C<pool_path>, C<domain_dir>, C<bridge_device>,
C<virbr_device>.  Undefined and empty values are ignored, which lets callers
pass unset command line options straight through.

=cut

sub new {
    my ($class, %opts) = @_;

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
    my ($class, %opts) = @_;

    my %given = map { $_ => $opts{$_} } grep { defined $opts{$_} && length $opts{$_} } keys %opts;
    my $uri = $given{uri};
    my $explicit = defined($uri) ? 1 : 0;
    $uri = $DEFAULT_URI unless $explicit;

    my $parsed = _parse_uri($uri)
      or die "Could not parse libvirt connection URI '$uri'\n";

    my $self = bless {
        %given,
        uri      => $uri,
        explicit => $explicit,
        %$parsed,
    }, $class;

    # A remote hypervisor we can't get a shell on is only half usable, and the
    # half that's missing (files, bridge detection) isn't optional.  Say so now
    # rather than three minutes into a provision run.
    die "The hypervisor at $uri is remote, but its transport gives us no shell.\n"
      . "Use an ssh transport instead, e.g. qemu+ssh://root\@"
      . ($self->{host} // 'hypervisor')
      . "/system, so we can reach its filesystem.\n"
      if !$self->is_local && !defined $self->ssh_host;

    return $self;
}

=head2 from_config($config, %override)

Build the hypervisor from a L<Config::Simple> object, with anything passed in
C<%override> (i.e. from the command line) winning over what the file says.  A
false C<$config> is fine and means "everything is defaulted".

Reads C<libvirt_uri> for the URI, and C<tf_dir>, C<pool_path>, C<domain_dir>,
C<bridge_device> and C<virbr_device> under their own names.

=cut

# Constructor option => the provision.conf key it reads.
my %CONFIG_KEY = (
    uri => 'libvirt_uri',
    map { $_ => $_ } qw{tf_dir pool_path domain_dir bridge_device virbr_device},
);

sub from_config {
    my ($class, $config, %override) = @_;

    my $param = sub {
        my ($key) = @_;
        return undef unless $config;
        my $val = $config->param($key);
        $val = $val->[0] if ref $val eq 'ARRAY';
        return (defined $val && length $val) ? $val : undef;
    };

    return $class->new(map { $_ => $override{$_} // $param->($CONFIG_KEY{$_}) } keys %CONFIG_KEY);
}

=head2 forget()

Drop the memoized instance.  Only tests should need this.

=cut

sub forget {
    undef $INSTANCE;
    return 1;
}

# A libvirt connection URI is a URI: driver[+transport]://[user@][host][:port]/path
#
# L<URI> knows nothing about the driver+transport scheme, so it hands back a
# URI::_foreign with no authority accessors.  Split it generically instead and
# re-parse the authority under a scheme URI does understand, which gets us
# userinfo, bracketed IPv6 and ports without a regex of our own.
sub _parse_uri {
    my ($uri) = @_;

    my ($scheme, $authority, $path) = URI::Split::uri_split($uri);
    return undef unless defined $scheme && length $scheme;

    my ($driver, $transport) = split(/\+/, $scheme, 2);
    return undef unless defined $driver && length $driver;

    my $server = (defined $authority && length $authority) ? URI->new("ssh://$authority") : undef;

    return {
        driver    => $driver,
        transport => $transport,
        user      => $server ? $server->user : undef,
        host      => ($server && defined $server->host && length $server->host) ? $server->host : undef,
        port      => $server ? $server->port : undef,
        path      => $path,
    };
}

=head1 IDENTITY

=head2 uri

The libvirt connection URI, defaulted to C<qemu:///system>.

=head2 explicit

Whether the URI was actually asked for, as opposed to defaulted.  When it
wasn't, we let libvirt resolve its own default connection exactly as C<virsh>
with no C<-c> would.

=head2 is_local

True when the hypervisor is this very machine, i.e. the historical behavior.

=head2 slug

A filesystem-safe token identifying this hypervisor, used to keep terraform
state for different hypervisors from stomping on each other.

=cut

sub uri      { return $_[0]->{uri} }
sub explicit { return $_[0]->{explicit} }

=head2 name

What F<hypervisors.conf> calls this hypervisor, or undef when it didn't come
from there.

=cut

sub name { return $_[0]->{name} }

sub is_local {
    my ($self) = @_;
    return !defined $self->{host};
}

sub slug {
    my ($self) = @_;
    my $slug = $self->{uri};
    $slug =~ s/[^A-Za-z0-9]+/_/g;
    $slug =~ s/\A_+|_+\z//g;
    return $slug;
}

=head2 ssh_host, ssh_user, ssh_port, ssh_target

Where to ssh to in order to run something on the hypervisor, all inferred from
the connection URI.  C<ssh_host> is undef when the transport can't give us a
shell, which C<new> refuses to build in the first place.  C<ssh_port> falls back
to 22, the way any other ssh client would.

=cut

sub ssh_host {
    my ($self) = @_;
    return undef unless defined $self->{host};

    # A bare qemu://host/system speaks libvirt's native remote transport, but
    # that still tunnels over ssh by default, so treat it as ssh-able too.
    return $self->{host} if !defined $self->{transport} || $SSH_TRANSPORT{ $self->{transport} };
    return undef;
}

sub ssh_user { return $_[0]->{user} }
sub ssh_port { return $_[0]->{port} }

sub ssh_target {
    my ($self) = @_;
    my $host = $self->ssh_host or return undef;
    my $user = $self->ssh_user;
    return defined $user ? "$user\@$host" : $host;
}

=head1 PATHS

=head2 tf_dir

Where terraform's config and state live, I<on this machine>.

Terraform state is per-hypervisor: one state dir shared between several would
have terraform believe resources on HV A live on HV B and destroy accordingly.
So anything but the default connection gets its own tree.

=head2 tf_config_dir

C<tf_dir> plus the C<config/> terraform actually runs in.

=head2 pool_path

Where the C<tf_disks> storage pool lives, I<on the hypervisor>.

=head2 domain_dir

Where the per-domain directories live.  This path has to mean the same thing on
both ends: the guest pulls its payload from the hypervisor's copy.

=cut

sub tf_dir {
    my ($self) = @_;
    return $self->{tf_dir} if defined $self->{tf_dir};
    return '/opt/terraform' if $self->uri eq $DEFAULT_URI;

    # A hypervisor out of hypervisors.conf has a name worth reading in a path.
    return '/opt/terraform/hv/' . ($self->name // $self->slug);
}

sub tf_config_dir { return $_[0]->tf_dir . '/config' }
sub pool_path     { return $_[0]->{pool_path} // '/opt/terraform/disks' }
sub domain_dir    { return $_[0]->{domain_dir} // '/opt/domains' }

=head2 authorized_keys

The C<authorized_keys> file of the hypervisor-side transfer user, which is the
account the guest scp's its payload out of.

=cut

sub authorized_keys {
    my ($self) = @_;
    return "$ENV{HOME}/.ssh/authorized_keys" if $self->is_local;

    my $home = $self->qx_hv('echo $HOME');
    chomp $home if defined $home;
    die "Could not determine the home directory of the transfer user on the hypervisor\n"
      unless defined $home && length $home;
    return "$home/.ssh/authorized_keys";
}

=head2 hv_user

The unprivileged user the guest will scp its payload back from.

=cut

sub hv_user {
    my ($self) = @_;
    return scalar getpwuid($<) if $self->is_local;
    return $self->ssh_user if defined $self->ssh_user;

    my $who = $self->qx_hv('id -un');
    chomp $who if defined $who;
    return $who;
}

=head1 RUNNING THINGS ON THE HYPERVISOR

=head2 ssh

The L<Net::OpenSSH::More> connection to the hypervisor, opened on first use and
kept, or undef when the hypervisor is this machine and there is nothing to
connect to.

Everything that has to reach the far side goes through this rather than through
a command line we built ourselves: it does the quoting, it reports the errors,
and it gives us sftp on the same connection for free.

=head2 qx_hv($shell_command)

C<qx()> equivalent.  Takes a shell string -- pipelines and all -- and returns
its stdout with the trailing newline already off.

=head2 system_hv(@argv)

C<system()> equivalent.  Takes an argv list, returns the exit code.  The
arguments are escaped for you, so they may contain anything.

=cut

sub ssh {
    my ($self) = @_;
    return undef if $self->is_local;
    return $self->{ssh} if $self->{ssh};

    my $target = $self->ssh_target;
    $self->{ssh} = eval {
        Net::OpenSSH::More->new(
            host => $self->ssh_host,
            port => $self->ssh_port,
            (defined $self->ssh_user ? (user => $self->ssh_user) : ()),

            # Our commands are one-shot, and some of them are pipelines the
            # persistent Expect shell would rather we didn't send it.
            use_persistent_shell => 0,
        );
    } or die "Could not ssh to the hypervisor at $target: $@\n";

    return $self->{ssh};
}

sub qx_hv {
    my ($self, $cmd) = @_;
    return qx{$cmd} if $self->is_local;

    my ($out, undef, undef) = $self->ssh->cmd($cmd);
    return $out;
}

sub system_hv {
    my ($self, @argv) = @_;
    return system(@argv) >> 8 if $self->is_local;
    return $self->ssh->cmd_exit_code(@argv);
}

=head1 FILES ON THE HYPERVISOR

Each of these is the obvious local filesystem call when the hypervisor is us,
and the same thing over sftp on the L</ssh> connection when it isn't.  The
C<sudo> option on the writers is for destinations under C</etc> and C</usr>:
sftp writes as whoever we logged in as, so those go to a staging path and get
moved into place afterwards.

=over 4

=item C<file_exists_hv($path)>

=item C<mkpath_hv(@paths)>

=item C<unlink_hv(@paths)>

=item C<read_text_hv($path)>

=item C<write_text_hv($path, $content, %opts)>

=item C<append_line_hv($path, $line)>

Append a line, but only if it isn't already there.

=item C<put_file($local, $remote, %opts)>

=item C<put_dir($local, $remote)>

Copy a whole directory tree across, contents and all.

=back

=cut

sub file_exists_hv {
    my ($self, $path) = @_;
    return -f $path ? 1 : 0 if $self->is_local;

    # -f, not -e: every caller wants a regular file, and a directory sitting
    # where one of these belongs is not the same answer.
    my $attrs = $self->ssh->sftp->stat($path) or return 0;
    return Fcntl::S_ISREG($attrs->perm) ? 1 : 0;
}

sub mkpath_hv {
    my ($self, @paths) = @_;
    if ($self->is_local) {
        File::Path::make_path(@paths);
        return 1;
    }

    my $sftp = $self->ssh->sftp;
    foreach my $path (@paths) {
        next if $sftp->stat($path);
        $sftp->mkpath($path) or return 0;
    }
    return 1;
}

sub unlink_hv {
    my ($self, @paths) = @_;
    if ($self->is_local) {
        unlink @paths;
        return 1;
    }
    return $self->system_hv(qw{rm -f}, @paths) == 0;
}

sub read_text_hv {
    my ($self, $path) = @_;
    return File::Slurper::read_text($path) if $self->is_local;
    return $self->ssh->sftp->get_content($path);
}

sub write_text_hv {
    my ($self, $path, $content, %opts) = @_;

    if ($self->is_local) {
        return $self->_write_local($path, $content, %opts);
    }

    # sftp can only write as the user we logged in as, so anything under /etc
    # or /usr goes to a staging path first and gets moved into place with sudo.
    my $staged = $opts{sudo} ? _staging_path() : $path;
    $self->ssh->write($staged, $content, '0644') or return 0;

    return 1 unless $opts{sudo};
    return $self->_sudo_install($staged, $path);
}

sub append_line_hv {
    my ($self, $path, $line) = @_;
    chomp $line;

    my $existing = '';
    if ($self->is_local) {
        $existing = File::Slurper::read_text($path) if -f $path;
    }
    elsif ($self->file_exists_hv($path)) {
        $existing = $self->read_text_hv($path) // '';
    }

    return 1 if grep { $_ eq $line } split(/\n/, $existing);

    $existing .= "\n" if length $existing && $existing !~ m/\n\z/;
    $self->mkpath_hv(_parent_dir($path));
    return $self->write_text_hv($path, $existing . "$line\n");
}

sub put_file {
    my ($self, $local, $remote, %opts) = @_;

    if ($self->is_local) {
        return $self->system_hv(qw{sudo cp}, $local, $remote) == 0
          if $opts{sudo} && !-w _parent_dir($remote);
        return File::Copy::copy($local, $remote) ? 1 : 0;
    }

    my $staged = $opts{sudo} ? _staging_path() : $remote;
    $self->ssh->sftp->put($local, $staged) or return 0;

    return 1 unless $opts{sudo};
    return $self->_sudo_install($staged, $remote);
}

sub put_dir {
    my ($self, $local, $remote) = @_;
    return 1 if $self->is_local;

    $self->mkpath_hv($remote) or return 0;
    return $self->ssh->sftp->rput($local, $remote) ? 1 : 0;
}

sub _write_local {
    my ($self, $path, $content, %opts) = @_;

    if ($opts{sudo} && !-w _parent_dir($path)) {
        my $tmp = _staging_path();
        File::Slurper::write_text($tmp, $content);
        my $ok = $self->_sudo_install($tmp, $path);
        unlink $tmp;
        return $ok;
    }

    File::Slurper::write_text($path, $content);
    return 1;
}

# Move a staged file into a root-owned destination.  mv keeps the staging
# user's ownership, which isn't what anything under /etc or /usr wants.
sub _sudo_install {
    my ($self, $staged, $path) = @_;
    return 0 if $self->system_hv(qw{sudo mv}, $staged, $path);
    $self->system_hv(qw{sudo chown root:root}, $path);
    return 1;
}

sub _staging_path { return '/tmp/.trog-hv-' . $$ . '-' . time() }

sub _parent_dir {
    my ($path) = @_;
    $path =~ s{/[^/]*\z}{};
    return length($path) ? $path : '/';
}

=head1 LIBVIRT

All of this goes through L<Sys::Virt>, which talks the connection URI's
transport itself.  There is no shelling out to C<virsh> and no assumption that
the hypervisor's libvirt is reachable any way other than the URI we were given.

=head2 vmm

The L<Sys::Virt> connection, opened on first use and kept.

=cut

sub vmm {
    my ($self) = @_;
    return $self->{vmm} if $self->{vmm};

    # An unasked-for URI means "whatever libvirt would pick", which is what
    # virsh with no -c did before any of this was configurable.
    my $uri = $self->explicit ? $self->uri : '';
    $self->{vmm} = eval { Sys::Virt->new(uri => $uri, readonly => 0) }
      or die "Could not connect to libvirt at " . $self->uri . ": $@\n";
    return $self->{vmm};
}

# Domain lookups throw when the domain is simply absent, which is not an error
# anywhere we ask.  Opening the connection happens outside the eval, so a
# hypervisor we can't reach at all doesn't get reported as "no such domain".
sub _domain {
    my ($self, $name) = @_;
    my $vmm = $self->vmm;
    return eval { $vmm->get_domain_by_name($name) };
}

=over 4

=item C<domain_exists($name)>

=item C<domain_is_running($name)>

=item C<domain_xml($name)>

The domain's XML description, or undef if there is no such domain.

=back

=cut

sub domain_exists     { return defined $_[0]->_domain($_[1]) ? 1 : 0 }
sub domain_is_running { my $d = $_[0]->_domain($_[1]); return $d && $d->is_active ? 1 : 0 }

sub domain_xml {
    my ($self, $name) = @_;
    my $domain = $self->_domain($name) or return undef;
    return $domain->get_xml_description();
}

=head2 annihilate_domain($name)

Stop and undefine a domain, nvram and all, and don't complain if it was already
gone or already off.  Terraform is not reliably able to do this itself, which is
the only reason we do.

Returns true if there was something there to remove.

=cut

sub annihilate_domain {
    my ($self, $name) = @_;
    my $domain = $self->_domain($name) or return 0;

    # A domain that is already shut off can't be destroyed, and that's the
    # normal case here rather than a problem.
    eval { $domain->destroy() };
    eval {
        $domain->undefine(Sys::Virt::Domain::UNDEFINE_NVRAM() | Sys::Virt::Domain::UNDEFINE_SNAPSHOTS_METADATA());
        1;
    } or do {
        # Older libvirt without nvram support for this domain type.
        eval { $domain->undefine() };
    };
    return 1;
}

=head2 lease_ip($network, $hostname, %opts)

The address libvirt has leased on C<$network> (usually C<default>) to the guest
calling itself C<$hostname>.  Pass C<exclude> to ignore a known-stale address,
which is how we tell a new lease from the one the old VM had.

=cut

sub lease_ip {
    my ($self, $network, $hostname, %opts) = @_;

    my $vmm = $self->vmm;
    my $net = eval { $vmm->get_network_by_name($network) } or return undef;
    my @leases = eval { $net->get_dhcp_leases() };
    return undef unless @leases;

    foreach my $lease (@leases) {
        next unless defined $lease->{hostname} && $lease->{hostname} =~ m/\Q$hostname\E/;
        next unless defined $lease->{ipaddr} && length $lease->{ipaddr};
        next if defined $opts{exclude} && $lease->{ipaddr} eq $opts{exclude};
        return $lease->{ipaddr};
    }
    return undef;
}

=head2 release_dhcp_lease($ip, $bridge)

Drop a stale lease so the table doesn't fill up and gum everything else.

This is the one libvirt operation we still shell out for: libvirt exposes DHCP
leases read-only (C<virNetworkGetDHCPLeases> has no counterpart that deletes
one), so releasing a lease means poking dnsmasq through libvirt's own lease
helper on the hypervisor.

=cut

sub release_dhcp_lease {
    my ($self, $ip, $bridge) = @_;
    return 0 unless defined $ip && length $ip;
    $bridge //= $self->virbr_device;

    my ($helper) = grep { $self->file_exists_hv($_) }
      qw{/usr/lib/libvirt/libvirt_leaseshelper /usr/libexec/libvirt_leaseshelper};
    unless ($helper) {
        warn "No libvirt lease helper found on the hypervisor, leaving the lease for $ip alone\n";
        return 0;
    }

    return $self->system_hv('sudo', "VIR_BRIDGE_NAME=$bridge", $helper, qw{del ip}, $ip) == 0 ? 1 : 0;
}

=head2 eject_cdrom($domain, $target)

Yank the cloud-init ISO back out, so the guest doesn't try to boot it again on
its next start.  C<$target> defaults to C<sda>, which is where the terraform
provider insists on putting it.

=cut

sub eject_cdrom {
    my ($self, $name, $target) = @_;
    $target //= 'sda';

    my $domain = $self->_domain($name) or return 0;
    my $xml    = qq{<disk type='file' device='cdrom'><driver name='qemu' type='raw'/><target dev='$target' bus='sata'/><readonly/></disk>};

    my $flags = Sys::Virt::Domain::DEVICE_MODIFY_LIVE() | Sys::Virt::Domain::DEVICE_MODIFY_CONFIG();
    my $ok    = eval { $domain->update_device($xml, $flags); 1 };
    warn "Could not eject the cloud-init cdrom from $name: $@" unless $ok;
    return $ok ? 1 : 0;
}

=head2 pool_uuid($name)

The UUID of a storage pool, or undef if it doesn't exist yet.  Terraform needs
this to adopt a pool it didn't create rather than fighting over it.

=head2 nuke_pool($name)

Tear a storage pool down completely -- stop it, delete its contents, forget it
-- and remove its directory from the hypervisor.  Terraform gets itself into
states only this can get it out of.

=cut

sub pool_uuid {
    my ($self, $name) = @_;
    my $vmm  = $self->vmm;
    my $pool = eval { $vmm->get_storage_pool_by_name($name) } or return undef;
    return $pool->get_uuid_string();
}

sub nuke_pool {
    my ($self, $name) = @_;

    # The directory goes first: pool-delete on a pool whose backing store is
    # already gone is a no-op, but the reverse leaves files libvirt still owns.
    $self->system_hv(qw{sudo rm -rf}, $self->pool_path);

    my $vmm  = $self->vmm;
    my $pool = eval { $vmm->get_storage_pool_by_name($name) };
    unless ($pool) {
        print "No storage pool named $name on " . $self->uri . ", nothing to nuke.\n";
        return 0;
    }

    foreach my $step (qw{destroy delete undefine}) {
        eval { $pool->$step(); 1 } or warn "pool $step failed for $name: $@";
    }
    return 1;
}

=head1 SNAPSHOTS

=head2 snapshot_names($domain)

Every snapshot the domain has, oldest first.  libvirt hands them back in no
particular order, so they get sorted by creation time here -- C<restore
--latest> and C<--oldest> mean nothing otherwise.

=head2 snapshot_current_name($domain)

The name of the domain's current snapshot, or undef if it has none.

=head2 create_snapshot($domain, $name)

Take a live atomic snapshot.  C<$name> may be undef, in which case libvirt names
it after the current time.  Returns true on success.

=head2 revert_snapshot($domain, $name)

Revert to a named snapshot and leave the domain running.  Returns true on
success.

=cut

sub snapshot_names {
    my ($self, $name) = @_;
    my $domain = $self->_domain($name) or return ();

    my @snaps = eval { $domain->list_all_snapshots() };
    return () unless @snaps;

    my @dated = map { { name => $_->get_name(), created => _snapshot_created($_) } } @snaps;
    return map  { $_->{name} }
           sort { $a->{created} <=> $b->{created} or $a->{name} cmp $b->{name} }
           grep { defined $_->{name} && length $_->{name} } @dated;
}

# <creationTime> is seconds since the epoch.  A snapshot without one sorts to
# the front, which is where an unknown age belongs.
sub _snapshot_created {
    my ($snap) = @_;
    my $xml = eval { $snap->get_xml_description() } // '';
    my ($created) = $xml =~ m{<creationTime>(\d+)</creationTime>};
    return $created // 0;
}

sub snapshot_current_name {
    my ($self, $name) = @_;
    my $domain = $self->_domain($name) or return undef;
    my $snap   = eval { $domain->current_snapshot() } or return undef;
    return $snap->get_name();
}

sub create_snapshot {
    my ($self, $name, $snapname) = @_;
    my $domain = $self->_domain($name) or die "No such domain $name on " . $self->uri . "\n";

    my $xml = '<domainsnapshot>';
    $xml .= '<name>' . _xml_escape($snapname) . '</name>' if defined $snapname && length $snapname;
    $xml .= '</domainsnapshot>';

    my $flags = Sys::Virt::DomainSnapshot::CREATE_ATOMIC();

    # LIVE only means anything for a running domain, and libvirt rejects it for
    # one that isn't.
    $flags |= Sys::Virt::DomainSnapshot::CREATE_LIVE() if $domain->is_active();

    my $ok = eval { $domain->create_snapshot($xml, $flags); 1 };
    warn "Snapshot of $name failed: $@" unless $ok;
    return $ok ? 1 : 0;
}

sub revert_snapshot {
    my ($self, $name, $snapname) = @_;
    my $domain = $self->_domain($name) or return 0;
    my $snap   = eval { $domain->get_snapshot_by_name($snapname) } or return 0;

    my $ok = eval { $snap->revert_to(Sys::Virt::DomainSnapshot::REVERT_RUNNING()); 1 };
    warn "Revert of $name to $snapname failed: $@" unless $ok;
    return $ok ? 1 : 0;
}

sub _xml_escape {
    my ($str) = @_;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    return $str;
}

=head1 HYPERVISOR FACTS

The network layout the guest templates need.  Each is autodetected on the
hypervisor unless the config pinned it, because C<brctl show | tail -n1> guesses
wrong often enough to be worth overriding.

=head2 bridge_device

The outbound bridge the guest's public interface attaches to.

=head2 virbr_device

The libvirt NAT bridge.

=head2 virbr_ip

The hypervisor's address on that NAT bridge, which is what the guest scp's from
and ships its logs to.

=head2 sshd_port

The port the hypervisor's sshd listens on.  Read out of C<sshd_config> rather
than off the wire, since there may be several sshd instances running.

=cut

sub bridge_device {
    my ($self) = @_;
    return $self->{bridge_device} if defined $self->{bridge_device};

    my $device = $self->qx_hv(q{brctl show | grep -vP 'vnet|virbr' | tail -n1 | awk '{print $1}'});
    chomp $device if defined $device;
    die "Could not determine outbound bridge device on " . $self->uri . "!\n"
      . "Set bridge_device in provision.conf if autodetection can't find it.\n"
      unless $device;

    return $self->{bridge_device} = $device;
}

sub virbr_device {
    my ($self) = @_;
    return $self->{virbr_device} if defined $self->{virbr_device};

    my $device = $self->qx_hv(q{brctl show | grep virbr | tail -n1 | awk '{print $1}'});
    chomp $device if defined $device;
    die "Could not determine libvirt network device on " . $self->uri . "!\n"
      . "Set virbr_device in provision.conf if autodetection can't find it.\n"
      unless $device;

    return $self->{virbr_device} = $device;
}

sub virbr_ip {
    my ($self) = @_;
    return $self->{virbr_ip} if defined $self->{virbr_ip};

    my $device = $self->virbr_device;
    my $ip     = $self->qx_hv("ip addr show dev $device | grep inet | head -n1 | awk '{print \$2}'");
    die "Could not determine IP address for $device\n" unless $ip;
    chomp $ip;
    $ip =~ s{/\d+\z}{};

    return $self->{virbr_ip} = $ip;
}

sub sshd_port {
    my ($self) = @_;
    return $self->{sshd_port} if defined $self->{sshd_port};

    my $port = $self->qx_hv(q{grep '^Port' /etc/ssh/sshd_config | awk '{print $2}'});
    chomp $port if defined $port;
    warn "Could not determine SSH port for the hypervisor, assuming 22\n" unless $port;

    return $self->{sshd_port} = ($port || 22);
}

=head1 CAPACITY

What the hypervisor has, what its guests have already been promised, and
whether one more will fit.  All of it comes from libvirt, so it is what the
hypervisor actually believes rather than what a config file claimed a year ago.

Memory is counted as I<committed> rather than I<used>: a guest that has been
promised 8G is holding 8G against us even while it idles at 400M.  Overcommit
memory and the OOM killer eventually picks one of your VMs.  CPUs are the other
way round -- overcommitting cores is normal and expected -- so those are
measured against C<cpu_overcommit> times the physical count.

=head2 reserve_memory, reserve_cpus, reserve_disk, max_guests, cpu_overcommit

The limits from F<hypervisors.conf>.  C<reserve_memory> is MB to leave for the
host itself, C<reserve_disk> is bytes to leave in the pool, C<max_guests> caps
the domain count (0 means no cap), and C<cpu_overcommit> is how many vCPUs per
physical CPU is considered acceptable.  They default to 2048MB, 1 CPU, 10GB, no
cap, and 4.

=cut

sub reserve_memory  { return $_[0]->{reserve_memory}  // 2048 }
sub reserve_cpus    { return $_[0]->{reserve_cpus}    // 1 }
sub reserve_disk    { return $_[0]->{reserve_disk}    // 10 * 1024 * 1024 * 1024 }
sub max_guests      { return $_[0]->{max_guests}      // 0 }
sub cpu_overcommit  { return $_[0]->{cpu_overcommit}  // 4 }

=head2 capacity

A snapshot of the hypervisor, cached for the life of the object:

    memory_mb        physical memory
    memory_committed committed to guests, running or not
    memory_free      what is left after the reserve
    cpus             physical CPUs
    cpus_allocatable cpus * cpu_overcommit
    cpus_committed   vCPUs handed to running guests
    cpus_free        what is left after the reserve
    disk_free        free bytes in the storage pool, after the reserve
    guests           how many domains it knows about

Dies if libvirt cannot be reached, since a hypervisor we cannot ask about is
not one we should be placing guests on.

=cut

sub capacity {
    my ($self) = @_;
    return $self->{capacity} if $self->{capacity};

    my $node = $self->vmm->get_node_info();
    my @domains = $self->vmm->list_all_domains();

    my ($memory_committed, $cpus_committed) = (0, 0);
    foreach my $domain (@domains) {
        my $info = eval { $domain->get_info() } or next;

        # maxMem is what the guest may grow into, and is what we have to hold
        # against the host whether or not it is using it yet.
        $memory_committed += ($info->{maxMem} // 0) / 1024;
        $cpus_committed   += ($info->{nrVirtCpu} // 0) if eval { $domain->is_active() };
    }

    my $memory_mb        = ($node->{memory} // 0) / 1024;
    my $cpus             = $node->{cpus} // 0;
    my $cpus_allocatable = $cpus * $self->cpu_overcommit;

    return $self->{capacity} = {
        memory_mb        => $memory_mb,
        memory_committed => $memory_committed,
        memory_free      => $memory_mb - $memory_committed - $self->reserve_memory,
        cpus             => $cpus,
        cpus_allocatable => $cpus_allocatable,
        cpus_committed   => $cpus_committed,
        cpus_free        => $cpus_allocatable - $cpus_committed - $self->reserve_cpus,
        disk_free        => $self->pool_free() - $self->reserve_disk,
        guests           => scalar @domains,
    };
}

=head2 pool_free($name)

Free bytes in the storage pool, or 0 when there isn't one yet -- a pool
terraform has not built has no space in it, which is the honest answer.

=cut

sub pool_free {
    my ($self, $name) = @_;
    $name //= 'tf_disks';

    my $vmm  = $self->vmm;
    my $pool = eval { $vmm->get_storage_pool_by_name($name) } or return 0;
    my $info = eval { $pool->get_info() } or return 0;
    return $info->{available} // 0;
}

=head2 shortfalls(%needs)

Every reason this hypervisor cannot take a guest wanting C<memory_mb>, C<cpus>
and C<disk_bytes>, in words a person can act on.  An empty list means it fits.

=cut

sub shortfalls {
    my ($self, %needs) = @_;

    my $have = $self->capacity;
    my @reasons;

    push @reasons, sprintf('needs %dMB of memory, %dMB free (%dMB physical, %dMB committed, %dMB reserved)',
        $needs{memory_mb}, $have->{memory_free},
        $have->{memory_mb}, $have->{memory_committed}, $self->reserve_memory)
      if ($needs{memory_mb} // 0) > $have->{memory_free};

    push @reasons, sprintf('needs %d vCPUs, %d free (%d CPUs x%d overcommit, %d committed, %d reserved)',
        $needs{cpus}, $have->{cpus_free},
        $have->{cpus}, $self->cpu_overcommit, $have->{cpus_committed}, $self->reserve_cpus)
      if ($needs{cpus} // 0) > $have->{cpus_free};

    push @reasons, sprintf('needs %dGB of disk, %dGB free in the pool after a %dGB reserve',
        _gb($needs{disk_bytes}), _gb($have->{disk_free}), _gb($self->reserve_disk))
      if ($needs{disk_bytes} // 0) > $have->{disk_free};

    push @reasons, sprintf('already has %d guests, and max_guests is %d', $have->{guests}, $self->max_guests)
      if $self->max_guests && $have->{guests} >= $self->max_guests;

    return @reasons;
}

sub _gb { return int(($_[0] // 0) / (1024 * 1024 * 1024)) }

=head2 headroom(%needs)

How comfortably this hypervisor would hold the guest, from 0 (exactly full) to
1 (empty), taken as the tightest of the three resources once the guest is on
it.  Placing by the tightest resource is what keeps one hypervisor from filling
its disk while the fleet still has plenty of RAM.

=cut

sub headroom {
    my ($self, %needs) = @_;

    my $have = $self->capacity;
    my @fractions;

    push @fractions, _fraction($have->{memory_free} - ($needs{memory_mb}  // 0), $have->{memory_mb});
    push @fractions, _fraction($have->{cpus_free}   - ($needs{cpus}       // 0), $have->{cpus_allocatable});
    push @fractions, _fraction($have->{disk_free}   - ($needs{disk_bytes} // 0), $have->{disk_free} + ($needs{disk_bytes} // 0));

    my ($tightest) = sort { $a <=> $b } @fractions;
    return $tightest;
}

sub _fraction {
    my ($left, $total) = @_;
    return 0 if !$total;
    my $fraction = $left / $total;
    return $fraction < 0 ? 0 : $fraction;
}

=head1 PROVISIONING

=head2 sync_domain_dir($domain)

Put the domain's directory on the hypervisor.

The guest pulls its payload off the hypervisor over the NAT network, so when the
hypervisor isn't us, C<domain_dir> has to exist on both ends.  The whole
directory goes, not just the tarball: what else lives in there is decided by
whatever provisions these domains, not by this repository, so we are in no
position to guess which parts the guest will reach for.

Note that this puts the guest's private key on the hypervisor too.  That is the
cost of the hypervisor being the machine the guest fetches from.

=cut

sub sync_domain_dir {
    my ($self, $domain) = @_;
    return 1 if $self->is_local;

    my $local = $self->domain_dir . "/$domain";
    return 1 unless -d $local;

    print "Shipping $local to the hypervisor...\n";
    $self->put_dir($local, $local)
      or die "Could not copy $local to the hypervisor\n";
    return 1;
}

=head2 guest_ssh_ip($config, $lease_ip)

Which address I<we> use to SSH into a guest.

On a local hypervisor the libvirt NAT lease is reachable and always was.  On a
remote one it isn't -- it only routes from the hypervisor itself -- so we need
the guest's bridged static address instead, and there is no way to guess it.

=cut

sub guest_ssh_ip {
    my ($self, $config, $lease_ip) = @_;
    return $lease_ip if $self->is_local;

    my ($ip) = grep { defined $_ && length $_ } $config->param('ips');
    die "Provisioning against a remote hypervisor (" . $self->uri . ") requires the guest to have a\n"
      . "routable address: set 'ips' in provision.conf.  The libvirt NAT lease ("
      . ($lease_ip // 'none')
      . ") is only\nreachable from the hypervisor itself.\n"
      unless $ip;
    return $ip;
}

=head1 SEE ALSO

L<Sys::Virt>

=cut

1;
