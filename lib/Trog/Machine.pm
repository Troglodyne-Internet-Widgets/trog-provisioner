package Trog::Machine;

use strict;
use warnings FATAL => 'all';

use File::Path();
use File::Copy();
use File::Temp();
use File::Slurper();
use Net::OpenSSH::More();

=head1 NAME

Trog::Machine - a machine we reach over SSH and put files on

=head1 SYNOPSIS

    # Not used directly.  See Trog::HV and Trog::Guest.
    $machine->run(qw{sudo systemctl restart rsyslog});
    $machine->write_text('/etc/rsyslog.d/10-vm.conf', $conf, sudo => 1);
    $machine->put_file($local, '/root/setup.sh', sudo => 1, mode => '0755');

=head1 DESCRIPTION

There are two machines in this toolkit that are not the one we are running on:
the hypervisor a guest is built on, and the guest itself.  Everything about
reaching them is the same -- one SSH connection, commands with exit statuses,
files that have to arrive somewhere they may not have permission to go -- so it
is all here, and L<Trog::HV> and L<Trog::Guest> add only what makes them
different.

=head2 Why none of this uses sftp

L<Net::SFTP::Foreign> does not fail when the far side refuses a write.  It
stops.  No error, no return, just a process sitting there until somebody
notices -- and a root-owned destination is enough to do it.  Neither
C<put_content> nor C<put> avoids that, and neither does staging the file
somewhere writable first, because the staging path was never the problem.

So nothing here goes over sftp.  Content is poured down the standard input of a
command, which reports what happened:

    $ssh->system({ stdin_data => $content }, qw{sudo tee}, $path)

C<sudo> goes in front of the write itself rather than in front of a move
afterwards, so a privileged destination is written correctly the first time and
there is no intermediate file whose location, ownership or mode can be wrong.

=head1 CLASS METHODS

=head2 new(%opts)

C<host>, C<user>, C<port> and C<key_path>, all optional.  Subclasses generally
work these out from something else and pass them down.

=cut

# Seconds of network silence before a remote command is called wedged.  This is
# the one that catches a stall promptly: it is inactivity rather than elapsed
# time, so a slow transfer that keeps moving is never touched by it.
our $TIMEOUT = 120;

# Wall-clock seconds before SIGALRM takes the decision out of the library's
# hands.  A backstop, not the mechanism: it has to be generous enough to let a
# tarball across a slow link finish, so it will not catch a hang as promptly as
# $TIMEOUT does.  Both are package variables so a caller who knows their own
# network can tighten them.
our $HANG_TIMEOUT = 600;

sub new {
    my ($class, %opts) = @_;
    return bless {%opts}, $class;
}

=head1 IDENTITY

=head2 ssh_host, ssh_user, ssh_port, ssh_key, ssh_target

Where and as whom to connect.  C<ssh_port> falls back to 22, the way any other
ssh client would.

=head2 is_local

Whether this "machine" is the one we are running on, in which case everything
below degrades to a plain local filesystem or C<system()> call.  Only a
hypervisor is ever local; a guest never is.

=head2 describe

What to call this machine in an error message.

=cut

sub ssh_host { return $_[0]->{host} }
sub ssh_user { return $_[0]->{user} }
sub ssh_port { return $_[0]->{port} // 22 }
sub ssh_key  { return $_[0]->{key_path} }
sub is_local { return 0 }

sub ssh_target {
    my ($self) = @_;
    my $host = $self->ssh_host or return undef;
    my $user = $self->ssh_user;
    return defined $user ? "$user\@$host" : $host;
}

sub describe { return $_[0]->ssh_target // 'this machine' }

=head1 THE CONNECTION

=head2 ssh

The L<Net::OpenSSH::More> connection, opened on first use and kept, or undef
when the machine is us and there is nothing to connect to.

=cut

sub ssh {
    my ($self) = @_;
    return undef if $self->is_local;
    return $self->{ssh} if $self->{ssh};

    $self->{ssh} = eval {
        Net::OpenSSH::More->new(
            host => $self->ssh_host,
            port => $self->ssh_port,
            (defined $self->ssh_user ? (user     => $self->ssh_user) : ()),
            (defined $self->ssh_key  ? (key_path => $self->ssh_key)  : ()),

            # Our commands are one-shot, and some of them are pipelines the
            # persistent Expect shell would rather we didn't send it.
            use_persistent_shell => 0,
        );
    } or die 'Could not ssh to ' . $self->describe . ": $@\n";

    return $self->{ssh};
}

=head1 RUNNING THINGS

=head2 capture($shell_command)

Takes a shell string -- pipelines and all -- and returns its standard output.

=head2 run(@argv)

Takes an argv list and returns the exit code.  The arguments are escaped for
you, so they may contain anything.  A single argument is handed to the far
side's shell instead, which is how you write a pipeline.

=cut

sub capture {
    my ($self, $cmd) = @_;
    return qx{$cmd} if $self->is_local;

    return $self->_unhang($cmd, sub { ($self->ssh->cmd($cmd))[0] });
}

sub run {
    my ($self, @argv) = @_;
    return system(@argv) >> 8 if $self->is_local;

    return $self->_unhang(join(' ', @argv), sub { $self->ssh->cmd_exit_code(@argv) });
}

=head1 FILES

Each of these is the obvious local filesystem call when the machine is us, and
a command over the connection when it isn't.  The C<sudo> option on the writers
is for destinations we have no business owning -- anything under C</etc>,
C</usr> or C</root>.  C<mode> says what to chmod the result to afterwards,
defaulting to 0644, since C<tee> would otherwise leave it to root's umask.

=over 4

=item C<file_exists($path)>

=item C<mkpath(@paths)>

=item C<remove(@paths)>

=item C<read_text($path)>

=item C<write_text($path, $content, %opts)>

=item C<append_line($path, $line)>

Append a line, but only if it isn't already there.

=item C<put_file($local, $remote, %opts)>

=item C<put_dir($local, $remote)>

Copy a whole directory tree across, contents and all.

=back

=cut

sub file_exists {
    my ($self, $path) = @_;
    return -f $path ? 1 : 0 if $self->is_local;
    return $self->run(qw{test -f}, $path) == 0 ? 1 : 0;
}

sub mkpath {
    my ($self, @paths) = @_;
    if ($self->is_local) {
        File::Path::make_path(@paths);
        return 1;
    }

    foreach my $path (@paths) {
        next if $self->run(qw{mkdir -p}, $path) == 0;

        # Somewhere above it belongs to root.  Make it anyway, then hand it to
        # the login user, who is the one that will be writing into it.
        my $user = $self->ssh_user // $self->capture('id -un');
        chomp $user if defined $user;
        return 0 if $self->run(qw{sudo mkdir -p}, $path);
        $self->run('sudo', 'chown', "$user:", $path);
    }
    return 1;
}

sub remove {
    my ($self, @paths) = @_;
    if ($self->is_local) {
        unlink @paths;
        return 1;
    }
    return $self->run(qw{rm -f}, @paths) == 0;
}

sub read_text {
    my ($self, $path) = @_;
    return File::Slurper::read_text($path) if $self->is_local;

    # capture(), not cmd(): cmd chomps, and a file's trailing newline is part
    # of the file.
    my $content = $self->_unhang("cat $path",
        sub { $self->ssh->capture({ timeout => $TIMEOUT }, 'cat', $path) });
    return $self->ssh->error ? undef : $content;
}

sub write_text {
    my ($self, $path, $content, %opts) = @_;
    return $self->_write_local($path, $content, %opts) if $self->is_local;
    return $self->_pour({ stdin_data => $content }, $path, %opts);
}

sub put_file {
    my ($self, $local, $remote, %opts) = @_;

    if ($self->is_local) {
        return $self->run(qw{sudo cp}, $local, $remote) == 0
          if $opts{sudo} && !-w _parent_dir($remote);
        return File::Copy::copy($local, $remote) ? 1 : 0;
    }

    return $self->_pour({ stdin_file => $local }, $remote, %opts);
}

sub put_dir {
    my ($self, $local, $remote) = @_;
    return 1 if $self->is_local;
    $self->mkpath($remote) or return 0;

    # Pack locally, then unpack on the far side out of the same stdin stream
    # everything else here uses.  One round trip, modes preserved, and a real
    # exit status at the end of it.
    my $tarball = File::Temp->new(SUFFIX => '.tar.gz', UNLINK => 1);
    close $tarball;
    return 0 if system('tar', '-C', $local, '-czf', "$tarball", '.');

    return $self->_run({ stdin_file => "$tarball" }, 'tar', '-C', $remote, '-xzf', '-');
}

sub append_line {
    my ($self, $path, $line) = @_;
    chomp $line;

    my $existing = '';
    if ($self->is_local) {
        $existing = File::Slurper::read_text($path) if -f $path;
    }
    elsif ($self->file_exists($path)) {
        $existing = $self->read_text($path) // '';
    }

    return 1 if grep { $_ eq $line } split(/\n/, $existing);

    $existing .= "\n" if length $existing && $existing !~ m/\n\z/;
    $self->mkpath(_parent_dir($path));
    return $self->write_text($path, $existing . "$line\n");
}

# Write a stream to a path on the far side.  See "Why none of this uses sftp".
sub _pour {
    my ($self, $stdin, $path, %opts) = @_;

    my @cmd = ($opts{sudo} ? (qw{sudo tee}) : ('tee'), $path);
    $self->_run({ %$stdin, stdout_discard => 1 }, @cmd) or return 0;

    # tee makes the file with root's umask, which is not a decision anything
    # under /etc should be left to.
    $self->run('sudo', 'chmod', ($opts{mode} // '0644'), $path) if $opts{sudo};
    return 1;
}

sub _run {
    my ($self, $opts, @cmd) = @_;

    my $ok = $self->_unhang(join(' ', @cmd),
        sub { $self->ssh->system({ timeout => $TIMEOUT, %$opts }, @cmd) });

    warn 'Remote ' . join(' ', @cmd) . ' failed: ' . ($self->ssh->error // 'unknown') . "\n" unless $ok;
    return $ok ? 1 : 0;
}

=head2 _unhang($what, $code)

Run something that talks to the far side under a SIGALRM, so a wedge is an
error with a name on it rather than a tool that sits there.

The library's own C<timeout> should get there first, and does for anything that
merely stalls.  This is for the case it cannot see: a call that has stopped
making progress without the connection noticing, which is exactly how sftp
behaved when the far side refused a write.  Nothing should ever reach it.

=cut

sub _unhang {
    my ($self, $what, $code) = @_;
    return $code->() if $self->is_local;

    my @result = eval {
        local $SIG{ALRM} = sub { die "__TROG_HUNG__\n" };
        alarm $HANG_TIMEOUT;
        my @r = $code->();
        alarm 0;
        @r;
    };
    my $error = $@;
    alarm 0;

    die 'Gave up on ' . $self->describe . " after ${HANG_TIMEOUT}s: $what\n"
      . "Nothing came back and nothing failed, which usually means a permission\n"
      . "problem the far side declined to report.  Check that "
      . ($self->ssh_user // 'the login user')
      . " can write where this was going.\n"
      if $error eq "__TROG_HUNG__\n";

    die $error if $error;
    return wantarray ? @result : $result[0];
}

sub _write_local {
    my ($self, $path, $content, %opts) = @_;

    if ($opts{sudo} && !-w _parent_dir($path)) {
        my $tmp = File::Temp->new(UNLINK => 1);
        print {$tmp} $content;
        close $tmp;
        my $ok = $self->run(qw{sudo cp}, "$tmp", $path) == 0;
        $self->run('sudo', 'chmod', ($opts{mode} // '0644'), $path) if $ok;
        return $ok ? 1 : 0;
    }

    File::Slurper::write_text($path, $content);
    return 1;
}

sub _parent_dir {
    my ($path) = @_;
    $path =~ s{/[^/]*\z}{};
    return length($path) ? $path : '/';
}

=head1 SEE ALSO

L<Trog::HV>, L<Trog::Guest>

=cut

1;
