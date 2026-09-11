package Trog::Machine;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';
use File::Basename();
use File::Path();
use File::Copy();
use File::Temp();
use File::Rsync();
use File::Slurper();
use IPC::Run3();
use File::Slurper::Temp();
use Net::OpenSSH::More();
use Trog::Credentials();

=head1 NAME

Trog::Machine - a machine we reach over SSH and put files on

=head1 SYNOPSIS

    # Not used directly.  See Trog::HV and Trog::Guest, either of which is a
    # Trog::Machine and answers to all of this.
    my $machine = Trog::HV->new();

    $machine->run_sudo(qw{systemctl restart libvirtd});
    $machine->write_text('/etc/libvirt/hooks/qemu', 'some hook', sudo => 1);
    $machine->put_file('setup.sh', '/root/setup.sh', sudo => 1, mode => '0755');

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

=head2 Why a directory comes over rsync

A whole directory is the one thing here that is neither poured down that stdin
nor run as a command: it goes through L<File::Rsync>, and it has to.

The tree usually being asked about is a domain's data directory -- tens of
gigabytes of video that changes by a handful of files between provisions -- and
a transport that cannot ask what is already at this end moves all of it every
run.  That is what the sftp fetch this replaced did, and it is the reason not to
go back to one.

The comparison is rsync's own quick check, size and mtime, not C<--checksum>.
Checksumming a twenty gigabyte data directory reads all of it at both ends every
run, which costs more than the transfer it exists to avoid.

None of the sftp reasoning above applies here: rsync reports what happened and
exits with a status, like anything else on this connection.

rsync has to be installed on both ends.  F<bin/preflight> checks this machine
and the hypervisor, and every guest this tool builds gets it among its base
packages.

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
    my ( $class, %opts ) = @_;
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
    my $host   = $self->ssh_host or return undef;
    my $user   = $self->ssh_user;
    return defined $user ? "$user\@$host" : $host;
}

sub describe { return $_[0]->ssh_target // 'this machine' }

=head1 THE MACHINE A GUEST FETCHES FROM

A guest pulls its payload -- the Makefile tarball, the domain's data, its
dotfiles -- off one of these over ssh.  Which machine that is has moved: it used
to be the hypervisor, back when the hypervisor was also the machine running this
tool, and it is now L<Trog::Local>, us.  These three are what the fetch needs to
know about whoever is holding the files, so they are here rather than on either
subclass.

=head2 transfer_user

The unprivileged account the guest fetches as.

=head2 authorized_keys

That account's C<authorized_keys>, which is where a guest's public key is
written so it can fetch at all.

=head2 sshd_port

The port that machine's sshd listens on.  Read out of its configuration rather
than off the wire, since there may be several sshd instances running.  22 when
nothing says otherwise, which is sshd's own default and not a guess.

=cut

sub transfer_user {
    my ($self) = @_;
    return scalar getpwuid($<) if $self->is_local;
    return $self->ssh_user     if defined $self->ssh_user;

    my $who = $self->capture_cmd('id -un');
    chomp $who if defined $who;
    return $who;
}

sub authorized_keys {
    my ($self) = @_;
    return "$ENV{HOME}/.ssh/authorized_keys" if $self->is_local;

    my $home = $self->capture_cmd('echo $HOME');
    chomp $home if defined $home;
    die 'Could not determine the home directory of the transfer user on ' . $self->describe . "\n"
      unless defined $home && length $home;
    return "$home/.ssh/authorized_keys";
}

sub sshd_port {
    my ($self) = @_;
    return $self->{sshd_port} if defined $self->{sshd_port};

    # sshd_config.d as well as sshd_config.  A modern Ubuntu ships an Include for
    # that directory at the top of the main file, so anything dropped in there
    # is what sshd actually uses -- reading only sshd_config finds the shipped
    # default and misses the answer.  Last match wins for the same reason: the
    # Include comes first, and sshd takes the first value it is given.
    my $port = $self->capture_cmd(q{grep -h '^Port ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -n1 | awk '{print $2}'});
    chomp $port if defined $port;

    # No Port line at all means 22.  That is sshd's own default rather than a
    # failure to find something, so it is not worth saying -- and this is asked
    # of ourselves on every provision, where it would be said every time.
    return $self->{sshd_port} = ( $port || 22 );
}

=head1 THE CONNECTION

=head2 ssh

The L<Net::OpenSSH::More> connection, opened on first use and kept, or undef
when the machine is us and there is nothing to connect to.

=cut

sub ssh {
    my ($self) = @_;
    return undef        if $self->is_local;
    return $self->{ssh} if $self->{ssh};

    $self->{ssh} = eval {
        Net::OpenSSH::More->new(
            host => $self->ssh_host,
            port => $self->ssh_port,
            ( defined $self->ssh_user ? ( user     => $self->ssh_user ) : () ),
            ( defined $self->ssh_key  ? ( key_path => $self->ssh_key )  : () ),

            # Our commands are one-shot, and some of them are pipelines the
            # persistent Expect shell would rather we didn't send it.
            use_persistent_shell => 0,
        );
    } or die 'Could not ssh to ' . $self->describe . ": $@\n";

    return $self->{ssh};
}

=head1 RUNNING THINGS

=head2 capture_cmd($shell_command)

Takes a shell string -- pipelines and all -- and returns its standard output.

=head2 run_cmd(@argv)

Takes an argv list and returns the exit code.  The arguments are escaped for
you, so they may contain anything.  A single argument is handed to the far
side's shell instead, which is how you write a pipeline.

Named for what they do rather than C<run> and C<capture>: those are the names
Perl::Critic::Policy::PreferredBinaries reads as a local runner, and these run
their command on whatever machine this is -- usually another one, where advice
to use a perl module instead makes no sense.

=cut

sub capture_cmd {
    my ( $self, $cmd ) = @_;
    if ( $self->is_local ) {

        # A string still reaches a shell, which is the documented contract here
        # -- callers write pipelines.  What run3 buys is stdin closed rather
        # than inherited, so a command that decides to read one cannot sit there
        # waiting on a terminal that is busy elsewhere.
        IPC::Run3::run3( $cmd, \undef, \my $out, undef );
        return $out;
    }

    return $self->_unhang( $cmd, sub { ( $self->ssh->cmd($cmd) )[0] } );
}

sub run_cmd {
    my ( $self, @argv ) = @_;
    return system(@argv) >> 8 if $self->is_local;

    return $self->_unhang( join( ' ', @argv ), sub { $self->ssh->cmd_exit_code(@argv) } );
}

=head1 SUDO

Almost everything this tool does on a hypervisor needs root, and C<sudo> over
an SSH connection has no terminal to ask for a password at.  Left alone it says
so and fails, which is how a run gets three minutes in and then stops on
something nobody can act on.

So: C<sudo -n> first, so a password requirement is an immediate, legible
failure rather than a wait on a terminal that will never appear.  If that is
what happened, ask for the password once, remember it for the rest of the run,
and carry on.

When there is nobody to ask -- a run driven by tCMS's reprovision button, or a
cron -- the password can be handed in before anything starts.  See
L<Trog::Credentials>.  Without that, such a run fails here rather than hanging,
which is the right way round but is still a run that did not happen.

The password never travels with the data.  C<sudo -S> reads it from standard
input, which is where C<put_file> and C<write_text> are already sending the
file, and sudo reading ahead into the content is not a thing to leave to
chance.  Privileged writes therefore land in a file we own and are moved into
place afterwards -- one command with the password on stdin, one with the
content, never both.

=head2 sudo_password

The remembered password for this machine, if we have had to ask for one.
Cached against the machine we asked about, so two objects pointing at the same
host share it and nobody gets asked twice.

=cut

# Passwords by target, so rebuilding a machine object does not ask again.
my %SUDO_PASSWORD;

sub sudo_password {
    my ($self) = @_;
    return $SUDO_PASSWORD{ $self->_sudo_key };
}

sub _sudo_key { return $_[0]->ssh_target // 'localhost' }

sub _remember { return $SUDO_PASSWORD{ $_[0]->_sudo_key } = $_[1] }

# A seam, so the no-terminal path is testable somewhere that has one.
sub _have_terminal { return -t STDIN ? 1 : 0 }

=head2 forget_sudo_passwords

Drop every remembered password.  Only tests should need this.

=cut

sub forget_sudo_passwords { %SUDO_PASSWORD = (); return 1 }

sub _ask_for_sudo_password {
    my ($self) = @_;

    # Handed to us up front, by whatever is driving a run that has nobody to ask.
    # Asked for before the terminal test rather than after it, because the whole
    # point is that there is no terminal.
    return $self->_remember( Trog::Credentials->get('sudo') ) if Trog::Credentials->have('sudo');

    die 'sudo on '
      . $self->describe
      . " wants a password, and there is no terminal to ask at.\n"
      . 'Either run this where it can ask, give '
      . ( $self->ssh_user // 'the login user' )
      . " passwordless sudo there:\n" . '    '
      . ( $self->ssh_user // 'youruser' )
      . " ALL=(ALL) NOPASSWD: ALL\n"
      . "in /etc/sudoers.d/, via visudo -- or hand the password in with --credentials, as Trog::Credentials describes.\n"
      unless $self->_have_terminal();

    my $password = Trog::Credentials->prompt( '[sudo] password for ' . ( $self->ssh_user // 'you' ) . ' on ' . $self->describe . ':', 'sudo' );

    die 'No password given for ' . $self->describe . "\n" unless defined $password && length $password;

    return $self->_remember($password);
}

# What sudo says when it wants a password it cannot ask for.
sub _wants_password {
    my ($output) = @_;
    return 0 unless defined $output;
    return $output =~ m/sudo: (?:a )?(?:password is required|a terminal is required|no password was provided)/ ? 1 : 0;
}

sub _wrong_password {
    my ($output) = @_;
    return 0 unless defined $output;
    return $output =~ m/sudo: \d+ incorrect password attempt|Sorry, try again/ ? 1 : 0;
}

=head2 run_sudo(@argv)

Run something as root, asking for a password if the far side turns out to want
one.  Returns the exit code, like C<run>.

=cut

sub run_sudo {
    my ( $self, @argv ) = @_;

    # A local sudo has our own terminal to ask at, so let it.
    return $self->run_cmd( 'sudo', @argv ) if $self->is_local;
    return $self->_run_sudo_attempt( 0, @argv );
}

sub _run_sudo_attempt {
    my ( $self, $attempts, @argv ) = @_;

    my $password = $self->sudo_password;
    my @sudo     = defined $password ? ( qw{sudo -S -p}, q{} )         : (qw{sudo -n});
    my %stdin    = defined $password ? ( stdin_data => "$password\n" ) : ();

    my ( $out, $err ) = $self->_unhang(
        join( ' ', 'sudo', @argv ),
        sub {
            $self->ssh->capture2( { timeout => $TIMEOUT, %stdin }, @sudo, @argv );
        }
    );
    my $rc = $? >> 8;
    return 0 unless $rc;

    my $said = ( $out // '' ) . ( $err // '' );
    return $rc unless _wants_password($said) || _wrong_password($said);

    # Three goes at typing it, then give up rather than loop.
    die 'Could not authenticate sudo on ' . $self->describe . "\n" if $attempts >= 3;

    # Not warn: this is the second half of a password prompt, being read by
    # somebody with a terminal in front of them, and a source location stapled
    # to it would be noise in the middle of them retyping it.
    print {*STDERR} "Sorry, try again.\n"     if _wrong_password($said);    ## no critic (ProhibitPrintSTDERR)
    delete $SUDO_PASSWORD{ $self->_sudo_key } if _wrong_password($said);
    $self->_ask_for_sudo_password();

    return $self->_run_sudo_attempt( $attempts + 1, @argv );
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

=item C<remove_tree(@paths)>

A directory and everything under it.

=item C<list_dir($path)>

What is in a directory, as names with no path on them and no dotfiles among
them.  Empty for a directory that is not there, the way C<glob> is: the callers
are asking what is left somewhere, and nothing is a perfectly good answer.

=item C<read_text($path)>

=item C<write_text($path, $content, %opts)>

=item C<append_line($path, $line)>

Append a line, but only if it isn't already there.

=item C<put_file($local, $remote, %opts)>

=item C<get_file($remote, $local)>

The other direction, for one file.

=item C<get_dir($remote, $local, %opts)>

A whole directory tree, contents and all.  Incremental: what is already here and
unchanged does not travel again.  See L</Why a directory comes over rsync>.

C<exclude> takes an arrayref of rsync patterns for things that must not come
down -- see C<remote_skip> in L<Provisioner::Recipe>, which is where the ones we
use are written.  C<update> leaves a file alone when our copy is the newer one.

C<sudo> runs the far end as root, for a tree the connecting user cannot read.  A
service keeps its state in a directory it owns and nobody else can open, and an
unprivileged fetch of one walks the tree, makes the local directories, copies
nothing out of them and exits happy -- which is indistinguishable from a guest
that has no state yet.  It needs passwordless sudo on the far side and fails
rather than waiting when there is none.

B<Nothing is ever deleted here.>  rsync could, and this is the only direction
left that it could apply to -- the two pushes that used to go to the hypervisor
are gone, so C<get_dir> is the only caller.  It must not: this is a salvage, and
the copy it is writing into is the only one there is.  A guest that stopped
producing something, or that could not be read on one run, would take our copy
of it with it.  The backup is the thing that mirrors a source and it deletes on
purpose, having history to fall back on; this has neither.

What arrives is owned by whoever is running this, not by the uids it had on the
guest: rsync only restores ownership when the B<receiving> end is root, and this
end is not.  Putting it back where the service wants it, as whoever the service
runs as, is C<scripts/restore_state>'s job and it is told the owner explicitly.

=back

=cut

sub file_exists {
    my ( $self, $path ) = @_;
    if ( $self->is_local ) {
        open( my $fh, '<', $path ) or return 0;
        close $fh;
        return 1;
    }
    return $self->run_cmd( qw{test -f}, $path ) == 0 ? 1 : 0;
}

sub mkpath {
    my ( $self, @paths ) = @_;
    if ( $self->is_local ) {
        File::Path::make_path(@paths);
        return 1;
    }

    foreach my $path (@paths) {
        next if $self->run_cmd( qw{mkdir -p}, $path ) == 0;

        # Somewhere above it belongs to root.  Make it anyway, then hand it to
        # the login user, who is the one that will be writing into it.
        my $user = $self->ssh_user // $self->capture_cmd('id -un');
        chomp $user if defined $user;
        return 0    if $self->run_sudo( qw{mkdir -p}, $path );
        $self->run_sudo( 'chown', "$user:", $path );
    }
    return 1;
}

sub remove {
    my ( $self, @paths ) = @_;
    if ( $self->is_local ) {
        unlink @paths;
        return 1;
    }
    return $self->run_cmd( qw{rm -f}, @paths ) == 0;
}

sub remove_tree {
    my ( $self, @paths ) = @_;
    if ( $self->is_local ) {
        File::Path::remove_tree(@paths);
        return 1;
    }
    return $self->run_cmd( qw{rm -rf}, @paths ) == 0;
}

sub list_dir {
    my ( $self, $path ) = @_;
    return map { File::Basename::basename($_) } glob "$path/*" if $self->is_local;

    # ls rather than a listing over the connection: sftp is not used here at
    # all, and for the same reason -- see above.
    my $listing = $self->capture_cmd("ls -1 $path 2>/dev/null") // '';
    return grep { length } split( "\n", $listing );
}

sub read_text {
    my ( $self, $path ) = @_;
    return File::Slurper::read_text($path) if $self->is_local;

    # capture(), not cmd(): cmd chomps, and a file's trailing newline is part
    # of the file.
    #
    # In scalar context, explicitly.  _unhang calls what it is given in list
    # context and hands a scalar caller the first element back -- and capture in
    # list context is one element per line, so without this every file read off
    # a remote machine came back as its first line.  Whether that was noticed
    # depended entirely on the file: a one-line one read perfectly.
    #
    # The exit status decides, not $ssh->error.  That is sticky -- it holds the
    # last error from anything on this connection -- so a command that failed
    # earlier on purpose, like the sudo -n probe, would make a cat that worked
    # perfectly well look like a failure.
    my $content = $self->_unhang(
        "cat $path",
        sub { scalar $self->ssh->capture( { timeout => $TIMEOUT }, 'cat', $path ) }
    );

    return $? >> 8 ? undef : $content;
}

sub write_text {
    my ( $self, $path, $content, %opts ) = @_;
    return $self->_write_local( $path, $content, %opts ) if $self->is_local;
    return $self->_pour( { stdin_data => $content }, $path, %opts );
}

sub put_file {
    my ( $self, $local, $remote, %opts ) = @_;

    if ( $self->is_local ) {

        # Copy it ourselves if we can; sudo is the fallback, not the forecast.
        return 1                                                       if File::Copy::copy( $local, $remote );
        return $self->run_sudo( qw{cp}, $local, $remote ) == 0 ? 1 : 0 if $opts{sudo};
        return 0;
    }

    return $self->_pour( { stdin_file => $local }, $remote, %opts );
}

sub get_dir {
    my ( $self, $remote, $local, %opts ) = @_;

    # Locally, whichever machine this is: the destination of a fetch is us.  And
    # ours to make, because rsync creates the last component of a destination and
    # not the path above it, which for a salvage is two or three levels down
    # inside a data directory that may itself be new this run.
    File::Path::make_path($local);

    return $self->_rsync( $self->_there($remote), _here($local), %opts );
}

sub get_file {
    my ( $self, $remote, $local ) = @_;
    return File::Copy::copy( $remote, $local ) ? 1 : 0 if $self->is_local;

    return $self->_run( { stdout_file => $local }, 'cat', $remote );
}

sub append_line {
    my ( $self, $path, $line ) = @_;
    chomp $line;

    # Append.  Never read-modify-write.
    #
    # This is somebody's authorized_keys, and the old version of this pulled the
    # file across, added a line and pushed the whole thing back -- so any read
    # that came back empty, for any reason at all, rewrote the file with one key
    # in it and locked its owner out of their own machine.  There is no version
    # of that which is worth the tidier code.
    $self->mkpath( _parent_dir($path) );

    if ( $self->is_local ) {
        my $existing = eval { File::Slurper::read_text($path) };
        return 1 if defined $existing && grep { $_ eq $line } split( "\n", $existing );
        open( my $fh, '>>', $path ) or die "Could not open $path: $!";
        print {$fh} "$line\n";
        close($fh);
        return 1;
    }

    # grep decides whether it is already there, on the far side, so the file
    # never has to make the trip.
    return 1 if $self->run_cmd( qw{grep -qxF --}, $line, $path ) == 0;

    return $self->_pour( { stdin_data => "$line\n" }, $path, append => 1 );
}

# Write a stream to a path on the far side.  See "Why none of this uses sftp"
# and "SUDO": the content and the sudo password both want stdin, so a
# privileged write is two commands and never one.
sub _pour {
    my ( $self, $stdin, $path, %opts ) = @_;

    my @tee = $opts{append} ? (qw{tee -a}) : ('tee');

    unless ( $opts{sudo} ) {
        return $self->_run( { %$stdin, stdout_discard => 1 }, @tee, $path );
    }

    return $self->_sudo_append( $stdin, $path ) if $opts{append};

    my $staged = $self->_staging_path or return 0;
    $self->_run( { %$stdin, stdout_discard => 1 }, 'tee', $staged ) or do {
        $self->remove($staged);
        return 0;
    };

    my $mode = $opts{mode} // '0644';
    my $ok =
         !$self->run_sudo( 'mv',    $staged,     $path )
      && !$self->run_sudo( 'chown', 'root:root', $path )
      && !$self->run_sudo( 'chmod', $mode,       $path );

    $self->remove($staged) unless $ok;
    return $ok ? 1 : 0;
}

# A privileged append.  It cannot be staged and moved -- that would replace the
# file rather than add to it -- and the content cannot ride on stdin beside a
# sudo password, so it is staged and then concatenated on.
sub _sudo_append {
    my ( $self, $stdin, $path ) = @_;

    my $staged = $self->_staging_path or return 0;
    my $ok     = $self->_run( { %$stdin, stdout_discard => 1 }, 'tee', $staged )
      && !$self->run_sudo( qw{sh -c}, sprintf( 'cat %s >> %s', _shq($staged), _shq($path) ) );

    $self->remove($staged);
    return $ok ? 1 : 0;
}

# The one place left that builds a shell command: >> has no argv spelling.
sub _shq {
    my ($str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

# Somewhere we can definitely write, made by the far side rather than guessed
# at: mktemp gives us a private file in a directory that exists.
sub _staging_path {
    my ($self) = @_;

    my $path = $self->capture_cmd('mktemp');
    chomp $path  if defined $path;
    return $path if defined $path && length $path && $path =~ m{\A/};

    warn 'Could not make a staging file on ' . $self->describe . "\n";
    return undef;
}

# How to name a directory to rsync.  The trailing slash is rsync's way of saying
# "the contents of this" rather than "this, inside that", and every transfer here
# means the contents.
sub _here { return "$_[0]/" }

sub _there {
    my ( $self, $path ) = @_;
    return _here($path) if $self->is_local;
    return $self->ssh_target . ':' . _here($path);
}

# The ssh rsync is to use.  Spelled out rather than left to rsync's default,
# because the port and the key are ours to know and neither reaches rsync from
# the environment -- and because a guest rebuilt an hour ago presents a host key
# nothing has seen before, which here is the run working rather than an attack.
# The options are the ones Net::OpenSSH::More puts on its own master, so both
# ways of reaching a machine agree about what they will accept from it.
#
# rsync word-splits this, so a path with a space in it would arrive as two
# arguments.  Nothing here has one: the keys are written by this tool into the
# domain directory it also names.
sub _rsh {
    my ($self) = @_;

    my @ssh = (
        'ssh', '-p', $self->ssh_port,
        '-o' => 'StrictHostKeyChecking=no',
        '-o' => 'UserKnownHostsFile=/dev/null',
        '-o' => 'GSSAPIAuthentication=no',
        '-o' => 'ConnectTimeout=180',
    );
    push( @ssh, '-i', $self->ssh_key ) if defined $self->ssh_key;

    return join( ' ', @ssh );
}

# One rsync, either direction.
#
# Deliberately not through _run or _unhang.  This is a local process rather than
# a command down the connection, and _unhang's limit is wall clock: it would call
# a transfer of a data directory hung at exactly $HANG_TIMEOUT however well it
# was going, which is the round-numbered failure that is never the timeout you
# are looking at.  rsync's own --timeout is silence rather than elapsed time, so
# a transfer that keeps moving has as long as it needs and one that stops is
# over.
sub _rsync {
    my ( $self, $src, $dest, %opts ) = @_;

    my @exclude = @{ $opts{exclude} // [] };

    my $rsync = File::Rsync->new(
        archive => 1,
        timeout => $TIMEOUT,

        # What moved, at the end.  The whole point of this is that an unchanged
        # tree should be able to say so, and without it a walk that sent nothing
        # looks exactly like one that sent twenty gigabytes.  Human units
        # because the number this exists to print is measured in gigabytes.
        stats            => 1,
        'human-readable' => 1,

        ( $self->is_local ? ()                       : ( rsh => $self->_rsh ) ),
        ( @exclude        ? ( exclude => \@exclude ) : () ),

        # As root at the far end, for a fetch of something the connecting user
        # cannot read.  A service keeps its state in a directory it owns and
        # nobody else can open, so an unprivileged rsync walks the tree, makes
        # the local directories, copies nothing out of them and exits happy.
        #
        # sudo -n rather than sudo: there is no terminal on the other end of
        # this, so a sudo that decides to ask for a password would sit there
        # until the timeout rather than failing.  -n makes it exit instead, and
        # rsync reports that as a failure the caller can see.
        ( $opts{sudo} ? ( 'rsync-path' => 'sudo -n rsync' ) : () ),

        # Whatever the guest has that is older than our copy stays where it is.
        # Carried over from the sftp fetch this replaced, which asked for the
        # same thing under the name newer_only.
        ( $opts{update} ? ( update => 1 ) : () ),
    );

    unless ( $rsync->exec( src => $src, dest => $dest ) ) {
        warn "rsync $src -> $dest failed (status " . ( $rsync->status // '?' ) . "):\n" . join( '', map { "    $_" } @{ $rsync->err || [] } );
        return 0;
    }

    my ($moved) = grep { m/^Total transferred file size/ } @{ $rsync->out || [] };
    print $moved if $moved;

    return 1;
}

sub _run {
    my ( $self, $opts, @cmd ) = @_;

    my $ok = $self->_unhang(
        join( ' ', @cmd ),
        sub { $self->ssh->system( { timeout => $TIMEOUT, %$opts }, @cmd ) }
    );

    warn 'Remote ' . join( ' ', @cmd ) . ' failed: ' . ( $self->ssh->error // 'unknown' ) . "\n" unless $ok;
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

# How long to let one command run before calling it hung: the default, or the
# command's own timeout plus a minute if it names a longer one.
sub _hang_limit {
    my ($what) = @_;
    return $HANG_TIMEOUT unless defined $what;

    my %seconds = ( '' => 1, s => 1, m => 60, h => 3600, d => 86400 );
    my $limit   = $HANG_TIMEOUT;

    while ( $what =~ m/\btimeout\s+(\d+)([smhd]?)\b/g ) {
        my $own = $1 * $seconds{ $2 // '' };
        $limit = $own + 60 if $own + 60 > $limit;
    }

    return $limit;
}

sub _unhang {
    my ( $self, $what, $code ) = @_;
    return $code->() if $self->is_local;

    # This alarm is for a command that should return promptly and does not.  A
    # command carrying its own timeout is saying how long it may legitimately
    # take, so it gets that long instead -- waiting for a guest to finish its
    # Makefile is a single command that blocks for the whole build.
    my $limit = _hang_limit($what);

    my @result = eval {
        local $SIG{ALRM} = sub { die "__TROG_HUNG__\n" };
        alarm $limit;
        my @r = $code->();
        alarm 0;
        @r;
    };
    my $error = $@;
    alarm 0;

    die 'Gave up on ' . $self->describe . " after ${limit}s: $what\n" . "Nothing came back and nothing failed, which usually means a permission\n" . "problem the far side declined to report.  Check that " . ( $self->ssh_user // 'the login user' ) . " can write where this was going.\n"
      if $error eq "__TROG_HUNG__\n";

    die $error if $error;
    return wantarray ? @result : $result[0];
}

# Write it ourselves if we can, and reach for sudo only when that fails.
#
# This used to ask -w about the parent directory first.  Writing is the only
# question worth asking: -w answers for a moment that has passed by the time we
# act on it, and it cannot see an immutable bit, a full disk or a read-only
# mount -- all of which say "no" to a write that -w said yes to.
sub _write_local {
    my ( $self, $path, $content, %opts ) = @_;

    return 1 if eval { File::Slurper::Temp::write_text( $path, $content ); 1 };
    die $@ unless $opts{sudo};

    my $tmp = File::Temp->new( UNLINK => 1 );
    print {$tmp} $content;
    close $tmp;
    my $ok = $self->run_sudo( qw{cp}, "$tmp", $path ) == 0;
    $self->run_sudo( 'chmod', ( $opts{mode} // '0644' ), $path ) if $ok;
    return $ok ? 1 : 0;
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
