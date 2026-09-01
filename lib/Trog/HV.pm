package Trog::HV;

# Represents the hypervisor we are provisioning against.
#
# Everything in this toolkit that used to assume "the HV is this machine"
# goes through here instead:
#   * the URI handed to terraform's libvirt provider and to virsh
#   * shell commands that have to run *on* the HV (brctl, ip, sshd_config, ...)
#   * files that have to live *on* the HV (the storage pool dir, virtiofs-better,
#     rsyslog drop-ins, the data.tar.gz the guest scp's back)
#
# When no URI is configured we are the HV, and every one of those degrades to
# exactly what the code did before: plain qx/system/File::* against the local FS.

use strict;
use warnings;

use File::Path();
use File::Copy();
use File::Temp();
use File::Slurper();

our $DEFAULT_URI = 'qemu:///system';

# Transports over which we can also get a shell on the HV.
my %SSH_TRANSPORT = map { $_ => 1 } qw{ssh libssh libssh2};

sub new {
    my ($class, %opts) = @_;

    my $uri      = $opts{uri};
    my $explicit = (defined($uri) && length($uri)) ? 1 : 0;
    $uri = $DEFAULT_URI unless $explicit;

    my $parsed = _parse_uri($uri)
      or die "Could not parse libvirt connection URI '$uri'\n";

    my $self = bless {
        uri      => $uri,
        explicit => $explicit,
        %$parsed,
    }, $class;

    # A tcp:// or tls:// URI tells us nothing about how to get a shell, and
    # even for qemu+ssh:// the user may want to reach the box differently
    # (jump host, alternate login).  Let the config say so explicitly.
    $self->{ssh_host} = $opts{ssh_host} if defined $opts{ssh_host} && length $opts{ssh_host};
    $self->{ssh_user} = $opts{ssh_user} if defined $opts{ssh_user} && length $opts{ssh_user};
    $self->{ssh_port} = $opts{ssh_port} if defined $opts{ssh_port} && length $opts{ssh_port};

    return $self;
}

# driver[+transport]://[user@][host][:port]/[path][?extraparams]
sub _parse_uri {
    my ($uri) = @_;

    my ($driver, $transport, $authority, $rest) = $uri =~ m{
        \A
        ([A-Za-z0-9]+)              # driver
        (?: \+ ([A-Za-z0-9]+) )?    # +transport
        ://
        ([^/?]*)                    # [user@]host[:port]
        (.*)                        # /path[?params]
        \z
    }x or return undef;

    my ($user, $hostport) = $authority =~ m/\A(?:([^\@]*)\@)?(.*)\z/;
    my ($host, $port);
    if ($hostport =~ m/\A\[([^\]]*)\](?::(\d+))?\z/) {    # bracketed IPv6
        ($host, $port) = ($1, $2);
    }
    else {
        ($host, $port) = $hostport =~ m/\A([^:]*)(?::(\d+))?\z/;
    }

    return {
        driver    => $driver,
        transport => $transport,
        user      => (defined $user  && length $user)  ? $user  : undef,
        host      => (defined $host  && length $host)  ? $host  : undef,
        port      => $port,
        path      => $rest,
    };
}

sub uri      { $_[0]->{uri} }
sub explicit { $_[0]->{explicit} }

# True when the hypervisor is this very machine, i.e. the historical behavior.
sub is_local {
    my ($self) = @_;
    return !defined $self->{host} && !defined $self->{ssh_host};
}

# Where to ssh to in order to run something on the HV, or undef if we can't.
sub ssh_host {
    my ($self) = @_;
    return $self->{ssh_host} if defined $self->{ssh_host};
    return undef unless defined $self->{host};
    # A bare qemu://host/system speaks libvirt's native remote transport, but
    # that still tunnels over ssh by default, so treat it as ssh-able too.
    return $self->{host} if !defined $self->{transport} || $SSH_TRANSPORT{ $self->{transport} };
    return undef;
}

sub ssh_user { $_[0]->{ssh_user} // $_[0]->{user} }
sub ssh_port { $_[0]->{ssh_port} // $_[0]->{port} }

sub ssh_target {
    my ($self) = @_;
    my $host = $self->ssh_host or return undef;
    my $user = $self->ssh_user;
    return defined $user ? "$user\@$host" : $host;
}

# A filesystem-safe token identifying this HV, used to keep terraform state
# for different hypervisors from stomping on each other.
sub slug {
    my ($self) = @_;
    my $slug = $self->{uri};
    $slug =~ s/[^A-Za-z0-9]+/_/g;
    $slug =~ s/\A_+|_+\z//g;
    return $slug;
}

sub _require_shell {
    my ($self) = @_;
    return if $self->is_local;
    return if defined $self->ssh_host;
    die "Cannot run commands on the hypervisor at "
      . $self->uri
      . ": that transport gives us no shell.\n"
      . "Set hv_ssh_host (and optionally hv_ssh_user/hv_ssh_port) in provision.conf so we can reach it.\n";
}

sub _shq {
    my ($str) = @_;
    $str = '' unless defined $str;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

# Wrap a shell snippet so it runs on the HV.
sub _wrap {
    my ($self, $cmd) = @_;
    return $cmd if $self->is_local;
    $self->_require_shell();
    my @ssh = ('ssh', '-o', 'BatchMode=yes');
    push @ssh, ('-p', $self->ssh_port) if $self->ssh_port;
    push @ssh, $self->ssh_target, _shq($cmd);
    return join(' ', @ssh);
}

#### Running things on the HV ##################################################

# qx() equivalent.  Takes a shell string, returns its stdout.
sub qx_hv {
    my ($self, $cmd) = @_;
    my $wrapped = $self->_wrap($cmd);
    return qx{$wrapped};
}

# system() equivalent.  Takes an argv list, returns the exit code.
sub system_hv {
    my ($self, @argv) = @_;
    return system(@argv) >> 8 if $self->is_local;
    return system($self->_wrap(join(' ', map { _shq($_) } @argv))) >> 8;
}

#### Running virsh #############################################################

sub virsh_argv {
    my ($self, @args) = @_;
    # Only pass -c when the user actually asked for a specific HV, so an
    # unconfigured run keeps whatever URI virsh resolves on its own.
    return ('virsh', ($self->explicit ? ('-c', $self->uri) : ()), @args);
}

sub virsh_qx {
    my ($self, @args) = @_;
    my $cmd = join(' ', map { _shq($_) } $self->virsh_argv(@args));
    return qx{$cmd};
}

# As above, but lets the caller keep a shell pipeline on the end.
sub virsh_pipe {
    my ($self, $args, $suffix) = @_;
    my $cmd = join(' ', map { _shq($_) } $self->virsh_argv(@$args));
    $cmd .= " $suffix" if defined $suffix && length $suffix;
    return qx{$cmd};
}

sub virsh_system {
    my ($self, @args) = @_;
    return system($self->virsh_argv(@args)) >> 8;
}

#### Files on the HV ###########################################################

sub file_exists_hv {
    my ($self, $path) = @_;
    return -f $path ? 1 : 0 if $self->is_local;
    return $self->system_hv('test', '-f', $path) == 0 ? 1 : 0;
}

sub mkpath_hv {
    my ($self, @paths) = @_;
    if ($self->is_local) {
        File::Path::make_path(@paths);
        return 1;
    }
    return $self->system_hv('mkdir', '-p', @paths) == 0;
}

sub unlink_hv {
    my ($self, @paths) = @_;
    if ($self->is_local) {
        unlink @paths;
        return 1;
    }
    return $self->system_hv('rm', '-f', @paths) == 0;
}

sub read_text_hv {
    my ($self, $path) = @_;
    return File::Slurper::read_text($path) if $self->is_local;
    return scalar $self->qx_hv('cat ' . _shq($path));
}

# Copy a local file onto the HV.  Set sudo => 1 for root-owned destinations.
sub put_file {
    my ($self, $local, $remote, %opts) = @_;

    if ($self->is_local) {
        if ($opts{sudo} && !-w _parent_dir($remote)) {
            return $self->system_hv('sudo', 'cp', $local, $remote) == 0;
        }
        return File::Copy::copy($local, $remote) ? 1 : 0;
    }

    my $staged = $opts{sudo} ? '/tmp/.trog-hv-' . $$ . '-' . time() : $remote;

    my @scp = ('scp', '-q', '-o', 'BatchMode=yes');
    push @scp, ('-P', $self->ssh_port) if $self->ssh_port;
    push @scp, $local, $self->ssh_target . ":$staged";
    return 0 if system(@scp) >> 8;

    return 1 unless $opts{sudo};
    return 0 if $self->system_hv('sudo', 'mv', $staged, $remote);
    # mv keeps the staging user's ownership, which isn't what anything under
    # /etc or /usr/libexec wants.
    $self->system_hv('sudo', 'chown', 'root:root', $remote);
    return 1;
}

sub write_text_hv {
    my ($self, $path, $content, %opts) = @_;

    if ($self->is_local && !$opts{sudo}) {
        File::Slurper::write_text($path, $content);
        return 1;
    }

    my $tmp = File::Temp->new(UNLINK => 1);
    print {$tmp} $content;
    close $tmp;
    chmod 0644, "$tmp";
    return $self->put_file("$tmp", $path, %opts);
}

# Append a line to a file on the HV, but only if it isn't already there.
sub append_line_hv {
    my ($self, $path, $line) = @_;
    chomp $line;

    if ($self->is_local) {
        if (-f $path) {
            my $existing = File::Slurper::read_text($path);
            return 1 if grep { $_ eq $line } split(/\n/, $existing);
        }
        else {
            File::Path::make_path(_parent_dir($path));
        }
        open(my $fh, '>>', $path) or die "Could not open $path: $!";
        print {$fh} "$line\n";
        close($fh);
        return 1;
    }

    my $dir = _parent_dir($path);
    my $cmd = sprintf(
        'mkdir -p %s; touch %s; grep -qxF -- %s %s || printf \'%%s\\n\' %s >> %s',
        _shq($dir), _shq($path), _shq($line), _shq($path), _shq($line), _shq($path),
    );
    return $self->system_hv('sh', '-c', $cmd) == 0;
}

sub _parent_dir {
    my ($path) = @_;
    $path =~ s{/[^/]*\z}{};
    return length($path) ? $path : '/';
}

# The unprivileged user the guest will scp its payload back from.
sub hv_user {
    my ($self) = @_;
    return scalar getpwuid($<) if $self->is_local;
    return $self->ssh_user if defined $self->ssh_user;
    my $who = $self->qx_hv('id -un');
    chomp $who if defined $who;
    return $who;
}

# Build an HV from a provision.conf plus whatever the CLI overrode.
sub from_config {
    my ($class, $config, %override) = @_;

    my $param = sub {
        my ($key) = @_;
        return undef unless $config;
        my $val = $config->param($key);
        $val = $val->[0] if ref $val eq 'ARRAY';
        return (defined $val && length $val) ? $val : undef;
    };

    return $class->new(
        uri      => $override{uri}      // $param->('libvirt_uri'),
        ssh_host => $override{ssh_host} // $param->('hv_ssh_host'),
        ssh_user => $override{ssh_user} // $param->('hv_ssh_user'),
        ssh_port => $override{ssh_port} // $param->('hv_ssh_port'),
    );
}

1;
