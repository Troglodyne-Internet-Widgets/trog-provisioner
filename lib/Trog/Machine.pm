package Trog::Machine;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use File::Path();
use Path::Tiny();
use File::Copy();
use File::Temp();
use List::Util qw{any};
use File::Rsync();
use File::Slurper();
use IPC::Run3();
use File::Slurper::Temp();
use Net::OpenSSH::More();
use Trog::Credentials();

=head1 NAME

Trog::Machine - a machine we reach over SSH and put files on

=head1 SYNOPSIS

    # You do not use this class directly.  Trog::HV, Trog::Guest and
    # Trog::Local are subclasses, and each one has all of these methods.
    my $machine = Trog::HV->new();

    $machine->run_sudo(qw{systemctl restart libvirtd});
    $machine->write_text('/etc/libvirt/hooks/qemu', 'some hook', sudo => 1);
    $machine->put_file('setup.sh', '/root/setup.sh', sudo => 1, mode => '0755');

=head1 DESCRIPTION

This toolkit reaches two machines other than the one it runs on: the hypervisor
that a guest is built on, and the guest itself.  The way to reach each one is
the same.  It is one SSH connection, commands with exit statuses, and files that
must arrive in places the login user cannot always write to.  So all of that is
here.  L<Trog::HV> and L<Trog::Guest> add only what makes them different.
L<Trog::Local> is the machine this tool runs on, with the same interface.

=head2 Why none of this uses sftp

L<Net::SFTP::Foreign> does not fail when the far side refuses a write.  It
stops.  It gives no error and does not return, and the process waits until
somebody notices.  A destination that root owns is enough to cause this.
C<put_content> and C<put> both do it.  A staging file in a writable place does
not help, because the staging path is not the problem.

So nothing here uses sftp.  This module sends content on the standard input of a
command, and that command reports what happened:

    $ssh->system({ stdin_data => $content }, 'tee', $path)

A destination that needs root takes two commands, because the content and the
sudo password both need standard input.  See L</SUDO>.

=head2 Why a directory comes over rsync

A whole directory is the one exception.  It does not go on standard input and it
is not run as a command.  It goes through L<File::Rsync>, and it must.

The usual tree is the data directory of a domain.  That is tens of gigabytes of
video, and only a few files change between provisions.  A transport that cannot
compare against what is already at this end moves all of it on every run.  So
do not replace rsync with a transport that cannot compare.

rsync compares with its own quick check, size and mtime, not C<--checksum>.  A
checksum of a twenty gigabyte data directory reads all of it at both ends on
every run.  That costs more than the transfer it exists to avoid.

The sftp problem above does not apply here.  rsync reports what happened and
exits with a status, like any other command on this connection.

rsync must be installed at both ends.  F<bin/preflight> checks this machine and
the hypervisor.  Every guest that this tool builds gets rsync among its base
packages.

=head1 CLASS METHODS

=head2 new(%opts)

Takes C<host>, C<user>, C<port> and C<key_path>, all optional, and returns the
object.  Subclasses usually calculate these values from other data and pass them
in.

=cut

# Seconds of network silence before a remote command counts as hung.  It
# measures inactivity, not elapsed time, so a slow transfer that keeps moving
# never trips it.
our $TIMEOUT = 120;

# Wall-clock seconds before SIGALRM stops the call.  This is a backstop, and it
# must be long enough for a tarball to cross a slow link.  So it catches a hang
# later than $TIMEOUT does.  A caller that knows its own network can lower
# either value.
our $HANG_TIMEOUT = 600;

sub new {
    my ( $class, %opts ) = @_;
    return bless {%opts}, $class;
}

=head1 IDENTITY

=head2 ssh_host, ssh_user, ssh_port, ssh_key, ssh_target

Where to connect, and as which user.  C<ssh_port> returns 22 when no port is
set, as any other ssh client does.  C<ssh_target> returns C<user@host>, or only
the host when no user is set, or undef when no host is set.

=head2 is_local

True when this "machine" is the one we run on.  Then each method below becomes a
plain local filesystem call or a C<system()> call.  A guest is never local.
L<Trog::Local> always is, and a hypervisor can be.

=head2 describe

The name for this machine in an error message: its C<ssh_target>, or "this
machine".

=cut

sub ssh_host ($self) { return $self->{host} }
sub ssh_user ($self) { return $self->{user} }
sub ssh_port ($self) { return $self->{port} // 22 }
sub ssh_key  ($self) { return $self->{key_path} }
sub is_local { return 0 }

sub ssh_target {
    my ($self) = @_;
    my $host   = $self->ssh_host or return undef;
    my $user   = $self->ssh_user;
    return defined $user ? "$user\@$host" : $host;
}

sub describe ($self) { return $self->ssh_target // 'this machine' }

=head1 THE MACHINE A GUEST FETCHES FROM

A guest pulls its payload over ssh from one of these machines.  The payload is
the Makefile tarball, the data of the domain and its dotfiles.  That machine is
L<Trog::Local>, which is us.  The fetch needs these three facts about the machine
that holds the files, so they are here and not on a subclass.

=head2 transfer_user

The unprivileged account that the guest fetches as.  Locally, that is the user
that runs this tool.  On a remote machine, it is the login user.

=head2 authorized_keys

The path of the C<authorized_keys> file of that account.  The public key of a
guest goes there, so that the guest can fetch.  Dies if it cannot find the home
directory on a remote machine.

=head2 sshd_port

The port that the sshd of that machine listens on.  It comes from the sshd
configuration, not from the network, because several sshd instances can run at
once.  If no C<Port> line exists, it returns 22, which is the sshd default.  The
object keeps the result.

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
      unless $home;
    return "$home/.ssh/authorized_keys";
}

sub sshd_port {
    my ($self) = @_;
    return $self->{sshd_port} if defined $self->{sshd_port};

    # Read sshd_config.d as well as sshd_config, because a modern Ubuntu
    # includes that directory from the main file.  Any match will do, because
    # sshd listens on every Port line that it reads, not only the first.
    my $port = $self->capture_cmd(q{grep -h '^Port ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -n1 | awk '{print $2}'});
    chomp $port if defined $port;

    # No Port line is the sshd default, not a failure, so it gets no warning on
    # every provision.
    return $self->{sshd_port} = ( $port || 22 );
}

=head1 THE CONNECTION

=head2 ssh

The L<Net::OpenSSH::More> connection.  It opens on first use and the object keeps
it.  Returns undef when the machine is us, because there is nothing to connect
to.  Dies if it cannot connect.

C<%opts> goes to the constructor.  So a caller that waits on a machine that is
still starting can increase C<retry_interval> and C<retry_max>.  Only the first
call can do this.  Every later call gets the existing connection and ignores its
options.

=cut

sub ssh {
    my ( $self, %opts ) = @_;
    return undef        if $self->is_local;
    return $self->{ssh} if $self->{ssh};

    $self->{ssh} = eval {
        Net::OpenSSH::More->new(
            host => $self->ssh_host,
            port => $self->ssh_port,
            ( defined $self->ssh_user ? ( user     => $self->ssh_user ) : () ),
            ( defined $self->ssh_key  ? ( key_path => $self->ssh_key )  : () ),

            # Our commands are one-shot, and some of them are pipelines that
            # the persistent Expect shell does not handle well.
            use_persistent_shell => 0,

            # A connection for this object only.  Otherwise the library returns
            # the one it cached for the same user, host and port, and does not
            # test it.  A guest rebuilt at the same address then gets the dead
            # connection of the old guest.
            no_cache => 1,

            # Last, so that the options of the caller win.
            %opts,
        );
    } or die 'Could not ssh to ' . $self->describe . ": $@\n";

    return $self->{ssh};
}

=head1 RUNNING THINGS

=head2 capture_cmd($shell_command)

Takes a shell string, which can be a pipeline, and returns its standard output.

=head2 run_cmd(@argv)

Takes an argv list and returns the exit code.  This module escapes the
arguments, so they can contain any character.  A single argument goes to the
shell of the far side instead, and that is how you write a pipeline.

These names say what the methods do.  They are not C<run> and C<capture>,
because Perl::Critic::Policy::PreferredBinaries reads those names as local
runners.  These methods run their command on whatever machine this is.  That is
usually another machine, where advice to use a perl module does not apply.

=cut

sub capture_cmd {
    my ( $self, $cmd ) = @_;
    if ( $self->is_local ) {

        # A string still goes to a shell, as documented, because callers write
        # pipelines.  run3 closes stdin, so a command that reads stdin cannot
        # wait on a terminal that is busy elsewhere.
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

Almost everything this tool does on a hypervisor needs root.  C<sudo> over an
SSH connection has no terminal to ask for a password on.  Without help, it says
so and fails, and a run stops three minutes in on an error that nobody can act
on.

So this module runs C<sudo -n> first.  If sudo needs a password, that command
fails at once with a clear message.  It does not wait on a terminal that never
appears.  Then the module asks for the password once, keeps it for the rest of
the run, and continues.

Sometimes nobody is there to ask, for example in a run from the reprovision
button of tCMS, or from cron.  Then give the password before the run starts, as
L<Trog::Credentials> describes.  Without it, such a run fails here and does not
hang.

The password never goes on the same stream as the data.  C<sudo -S> reads it
from standard input, and C<put_file> and C<write_text> send the file on standard
input too.  If sudo reads past the password into the content, the result is
wrong.  So a privileged write goes first to a file that we own, and C<sudo>
moves it into place.  One command gets the password on stdin and one gets the
content, never both.

=head2 sudo_password

The password kept for this machine, or undef if we did not ask for one.  The key
is the target of the machine, so two objects for the same host share it and
nobody is asked twice.

=cut

my %SUDO_PASSWORD;

sub sudo_password {
    my ($self) = @_;
    return $SUDO_PASSWORD{ $self->_sudo_key };
}

sub _sudo_key ($self) { return $self->ssh_target // 'localhost' }

sub _remember ( $self, $password ) { return $SUDO_PASSWORD{ $self->_sudo_key } = $password }

=head2 forget_sudo_passwords

Clears every kept password.  Only the tests use this.

=cut

sub forget_sudo_passwords { %SUDO_PASSWORD = (); return 1 }

sub _ask_for_sudo_password {
    my ($self) = @_;

    # Given before the run, by a caller that has nobody to ask.
    return $self->_remember( Trog::Credentials->get('sudo') ) if Trog::Credentials->have('sudo');

    # Ask at the terminal, not on stdin, because cron and redirected runs
    # point stdin where nobody types.
    my $password;
    eval {
        $password = Trog::Credentials->prompt( '[sudo] password for ' . ( $self->ssh_user // 'you' ) . ' on ' . $self->describe . ':', 'sudo', terminal => 1 );
        1;
    } or do {
        die 'sudo on '
          . $self->describe
          . " wants a password, and it could not be asked for:\n"
          . $@
          . 'Either run this where it can ask, give '
          . ( $self->ssh_user // 'the login user' )
          . " passwordless sudo there:\n" . '    '
          . ( $self->ssh_user // 'youruser' )
          . " ALL=(ALL) NOPASSWD: ALL\n"
          . "in /etc/sudoers.d/, via visudo -- or hand the password in with --credentials, as Trog::Credentials describes.\n";
    };

    die 'No password given for ' . $self->describe . "\n" unless length $password;    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a password of "0" is still a password

    return $self->_remember($password);
}

# What sudo prints when it needs a password that it cannot ask for.
our @WANTS_PASSWORD = ( 'sudo: a password is required', 'sudo: password is required', 'sudo: a terminal is required', 'sudo: no password was provided' );

sub _wants_password {
    my ($output) = @_;
    return 0 unless defined $output;
    return ( any { index( $output, $_ ) >= 0 } @WANTS_PASSWORD ) ? 1 : 0;
}

sub _wrong_password {
    my ($output) = @_;
    return 0 unless defined $output;
    return $output =~ m/sudo:\s\d+\sincorrect\spassword\sattempt|Sorry,\stry\sagain/ ? 1 : 0;
}

=head2 run_sudo(@argv)

Runs C<@argv> as root, and asks for a password if the far side needs one.
Returns the exit code, like C<run_cmd>.  Dies if it cannot ask for a password,
or after three wrong ones.

=cut

sub run_sudo {
    my ( $self, @argv ) = @_;

    # A local sudo can ask at our own terminal.
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

    # Three tries, then stop.
    die 'Could not authenticate sudo on ' . $self->describe . "\n" if $attempts >= 3;

    # Not warn: this is part of a password prompt, and a source location in it
    # is noise to somebody who is typing the password again.
    print {*STDERR} "Sorry, try again.\n"     if _wrong_password($said);    ## no critic (ProhibitPrintSTDERR)
    delete $SUDO_PASSWORD{ $self->_sudo_key } if _wrong_password($said);
    $self->_ask_for_sudo_password();

    return $self->_run_sudo_attempt( $attempts + 1, @argv );
}

=head1 FILES

Each of these is the plain local filesystem call when the machine is us, and a
command over the connection when it is not.  The C<sudo> option on the writers
is for destinations that the login user does not own, such as anything under
C</etc>, C</usr> or C</root>.  With C<sudo>, C<mode> sets the permissions of the
result, and the default is 0644.  The chmod is necessary because a staging file
from C<mktemp> is 0600, and a local copy through sudo gets the umask of root.  A
write without C<sudo> leaves the mode to the writer.

=over 4

=item C<file_exists($path)>

True if C<$path> is a plain file.

=item C<mkpath(@paths)>

Makes each directory and its parents.  On a remote machine, if the login user
cannot make one, it uses C<sudo> and gives the directory to the login user.
Returns 0 if that fails.

=item C<remove(@paths)>

Deletes each file.

=item C<remove_tree(@paths)>

Deletes each directory and everything under it.

=item C<list_dir($path)>

Returns the names in a directory, with no path and no dotfiles.  Returns an
empty list for a directory that does not exist, as C<glob> does.  The callers ask
what is left in a place, and "nothing" is a valid answer.

=item C<read_text($path)>

Returns the content of the file.  On a remote machine, returns undef if the read
fails.  Locally, dies if the read fails.

=item C<write_text($path, $content, %opts)>

Writes C<$content> to C<$path>.  Takes C<sudo> and C<mode>.  Returns 1 on
success and 0 on failure.  Locally, without C<sudo>, dies on failure.

=item C<append_line($path, $line)>

Appends a line, but only if the file does not already contain it.

=item C<put_file($local, $remote, %opts)>

Copies one file from here to there.  Takes C<sudo> and C<mode>.  Returns 1 on
success and 0 on failure.

=item C<get_dir($remote, $local, %opts)>

Copies a whole directory tree from that machine to here.  It is incremental: a
file that is already here and did not change does not travel again.  See
L</Why a directory comes over rsync>.  Returns 1 on success.  On failure, warns
with the rsync errors and returns 0.

C<exclude> takes an arrayref of rsync patterns for paths that must not come
down.  The patterns in use come from C<remote_skip> in L<Provisioner::Recipe>.
C<update> keeps our copy of a file when it is the newer one.

C<sudo> runs the far end as root, for a tree that the login user cannot read.  A
service keeps its state in a directory that only it can open.  An unprivileged
fetch of that directory walks the tree, makes the local directories, copies no
files, and exits with success.  That looks the same as a guest with no state.
C<sudo> needs passwordless sudo on the far side, and without it the fetch fails
and does not wait.

B<Nothing is ever deleted here.>  C<get_dir> is a salvage, and the copy that it
writes into is the only copy.  If a guest stops making something, or one run
cannot read it, a delete removes our copy too.  The backup mirrors a source and
deletes on purpose, because it has history to fall back on.  A salvage has no
history.

The files that arrive belong to the user that runs this tool, not to the uids
that they had on the guest.  rsync restores ownership only when the
B<receiving> end is root, and this end is not.  C<scripts/restore_state> puts
the files back as the user that the service runs as.  The caller gives it that
owner.

=back

=cut

sub file_exists {
    my ( $self, $path ) = @_;
    return -f $path                                  ? 1 : 0 if $self->is_local;    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- the question test -f asks of a remote machine
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
    if ( $self->is_local ) {
        return () unless -d $path;
        my @names = sort map { $_->basename } Path::Tiny::path($path)->children(qr/\A[^.]/);
        return @names;
    }

    # ls, not sftp.  See "Why none of this uses sftp".
    my $listing = $self->capture_cmd( 'ls -1 ' . _shq($path) . ' 2>/dev/null' ) // '';
    return grep { $_ } split( m/\n/, $listing );
}

sub read_text {
    my ( $self, $path ) = @_;
    return File::Slurper::read_text($path) if $self->is_local;

    # capture(), not cmd(): cmd chomps, and the trailing newline is part of the
    # file.
    #
    # Scalar context, explicitly.  _unhang calls its code in list context and
    # gives a scalar caller the first element, and capture in list context
    # returns one element per line.
    #
    # The exit status decides, not $ssh->error.  That error is sticky: it holds
    # the last error from anything on this connection.  So an earlier failure on
    # purpose, such as the sudo -n probe, makes a good cat look like a failure.
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

        # Copy it ourselves if we can, and use sudo only if that fails.
        return 1 if File::Copy::copy( $local, $remote );
        return 0 unless $opts{sudo};
        return 0 if $self->run_sudo( qw{cp}, $local, $remote );
        return $self->run_sudo( 'chmod', ( $opts{mode} // '0644' ), $remote ) == 0 ? 1 : 0;
    }

    return $self->_pour( { stdin_file => $local }, $remote, %opts );
}

sub get_dir {
    my ( $self, $remote, $local, %opts ) = @_;

    # Local whichever machine this is, because the destination of a fetch is us.
    # rsync creates only the last component of a destination, and a salvage goes
    # two or three levels down in a data directory that can be new this run.
    File::Path::make_path($local);

    return $self->_rsync( $self->_there($remote), _here($local), %opts );
}

sub append_line {
    my ( $self, $path, $line ) = @_;
    chomp $line;

    # Append, never read-modify-write.  This is often an authorized_keys file,
    # and a rewrite after an empty read leaves one key and locks its owner out.
    $self->mkpath( _parent_dir($path) );

    if ( $self->is_local ) {
        my $existing = eval { File::Slurper::read_text($path) };
        return 1 if defined $existing && any { $_ eq $line } split( m/\n/, $existing );
        open( my $fh, '>>', $path ) or die "Could not open $path: $!";
        print {$fh} "$line\n";
        close($fh) or die "Could not close $path: $!";
        return 1;
    }

    # grep on the far side decides if the line is already there, so the file
    # never makes the trip.
    return 1 if $self->run_cmd( qw{grep -qxF --}, $line, $path ) == 0;

    return $self->_pour( { stdin_data => "$line\n" }, $path, append => 1 );
}

=head1 INTERNALS

Private to this module.  They are documented here for the next person to edit
them.

=head2 _pour(\%stdin, $path, %opts)

Writes a stream to C<$path> on the far side.  C<\%stdin> holds C<stdin_data> or
C<stdin_file>.  Takes C<append>, C<sudo> and C<mode>.  Returns 1 on success and
0 on failure.

A privileged write is always two commands, because the content and the sudo
password both need standard input.  See L</Why none of this uses sftp> and
L</SUDO>.

=cut

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

=head2 _sudo_append(\%stdin, $path)

Appends a stream to C<$path> as root.  Returns 1 on success and 0 on failure.

A move of a staged file replaces the file, and the content cannot go on stdin
next to a sudo password.  So the content goes to a staging file, and
C<sudo sh -c> concatenates it onto C<$path>.

=cut

sub _sudo_append {
    my ( $self, $stdin, $path ) = @_;

    my $staged = $self->_staging_path or return 0;
    my $ok     = $self->_run( { %$stdin, stdout_discard => 1 }, 'tee', $staged )
      && !$self->run_sudo( qw{sh -c}, sprintf( 'cat %s >> %s', _shq($staged), _shq($path) ) );

    $self->remove($staged);
    return $ok ? 1 : 0;
}

=head2 _shq($string)

Returns C<$string> quoted for a POSIX shell, for a command that has to be one
string.  C<_sudo_append> uses it because C<<< >> >>> has no argv form, and
C<list_dir> uses it for the path it lists.

=cut

sub _shq {
    my ($str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

=head2 _staging_path

Returns the path of a new private file on the far side.  C<mktemp> makes it
there, so the directory exists and we can write to it.  Warns and returns undef
if C<mktemp> fails.

=cut

sub _staging_path {
    my ($self) = @_;

    my $path = $self->capture_cmd('mktemp');
    chomp $path  if defined $path;
    return $path if $path && $path =~ m{\A/};

    warn 'Could not make a staging file on ' . $self->describe . "\n";
    return undef;
}

=head2 _here($path), _there($path)

Return the rsync name for a directory.  The trailing slash tells rsync "the
contents of this", not "this, inside that".  Every transfer here means the
contents.  C<_there> adds C<user@host:> for a remote machine.

=cut

sub _here { return "$_[0]/" }

sub _there {
    my ( $self, $path ) = @_;
    return _here($path) if $self->is_local;
    return $self->ssh_target . ':' . _here($path);
}

=head2 _rsh

Returns the ssh command for rsync to use.  It names the port and the key,
because neither reaches rsync from the environment.  It accepts any host key,
because a guest rebuilt an hour ago has a new host key, and that is normal here.
The options are the ones that Net::OpenSSH::More puts on its own master.  So both
ways to reach a machine accept the same things from it.

rsync splits this string on spaces, so a path with a space becomes two
arguments.  No path here has one, because this tool writes the keys into the
domain directory that it also names.

=cut

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

=head2 _rsync($src, $dest, %opts)

Runs one rsync from C<$src> to C<$dest>.  Takes C<exclude>, C<sudo> and
C<update>, as C<get_dir> describes.  Prints the total size transferred.
Returns 1 on success.  On failure, warns with the rsync errors and returns 0.

This does not go through C<_run> or C<_unhang>.  rsync is a local process, not a
command down the connection.  The limit of C<_unhang> is wall-clock time, so it
stops a long data transfer at exactly C<$HANG_TIMEOUT>, however well it goes.
The C<--timeout> of rsync measures silence, not elapsed time.  So a transfer
that keeps moving has as long as it needs, and one that stops ends.

=cut

sub _rsync {
    my ( $self, $src, $dest, %opts ) = @_;

    my @exclude = @{ $opts{exclude} // [] };

    my $rsync = File::Rsync->new(
        archive => 1,
        timeout => $TIMEOUT,

        # Report what moved, so that an unchanged tree says so.  Human units,
        # because that number is usually in gigabytes.
        stats            => 1,
        'human-readable' => 1,

        ( $self->is_local ? ()                       : ( rsh => $self->_rsh ) ),
        ( @exclude        ? ( exclude => \@exclude ) : () ),

        # See get_dir for why.  sudo -n, because no terminal at the far end can
        # answer a password prompt.  -n exits, and rsync reports the failure.
        ( $opts{sudo} ? ( 'rsync-path' => 'sudo -n rsync' ) : () ),

        ( $opts{update} ? ( update => 1 ) : () ),
    );

    unless ( $rsync->exec( src => $src, dest => $dest ) ) {
        warn "rsync $src -> $dest failed (status " . ( $rsync->status // '?' ) . "):\n" . join( '', map { "    $_" } @{ $rsync->err || [] } );
        return 0;
    }

    my ($moved) = grep { m/^Total[ ]transferred[ ]file[ ]size/ } @{ $rsync->out || [] };
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

=head2 _hang_limit($what)

Returns how many seconds one command can run before it counts as hung.  That is
C<$HANG_TIMEOUT>, or the command's own C<timeout> plus 60 seconds if that is
longer.

=cut

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

=head2 _unhang($what, $code)

Runs C<$code>, which talks to the far side, under a SIGALRM.  So a hung call
becomes an error with a name, and the tool does not wait forever.  C<$what>
names the command in the error and sets the limit, as C<_hang_limit> describes.
Returns what C<$code> returns.  Dies with "Gave up on" when the alarm fires, and
passes on any other error from C<$code>.  Locally, it runs C<$code> with no
alarm.

The library's own C<timeout> stops a call that only stalls, and it acts first.
This alarm is for a case that the library cannot see: a call that stops making
progress while the connection seems fine.  sftp does this when the far side
refuses a write.  In normal use, nothing reaches this alarm.

=cut

sub _unhang {
    my ( $self, $what, $code ) = @_;
    return $code->() if $self->is_local;

    # A command with its own timeout, such as a wait for the Makefile of a
    # guest, blocks for that long on purpose.
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

=head2 _write_local($path, $content, %opts)

Writes C<$content> to a local C<$path>.  If that fails and C<sudo> is set, it
copies the content into place with C<sudo cp> and sets C<mode>, 0644 by default.
Without C<sudo>, it dies on failure.  Returns 1 on success and 0 on failure.

The write itself is the test of access.  A C<-w> test describes a moment that is
already past.  It also cannot see an immutable bit, a full disk or a read-only
mount.

=cut

sub _write_local {
    my ( $self, $path, $content, %opts ) = @_;

    return 1 if eval { File::Slurper::Temp::write_text( $path, $content ); 1 };
    die $@ unless $opts{sudo};

    my $tmp = File::Temp->new( UNLINK => 1 );
    print {$tmp} $content;
    close($tmp) or die "Could not close $tmp: $!";
    my $ok = $self->run_sudo( qw{cp}, "$tmp", $path ) == 0;
    $self->run_sudo( 'chmod', ( $opts{mode} // '0644' ), $path ) if $ok;
    return $ok ? 1 : 0;
}

sub _parent_dir {
    my ($path) = @_;
    $path =~ s{/[^/]*\z}{};
    return $path ? $path : '/';
}

=head1 SEE ALSO

L<Trog::HV>, L<Trog::Guest>, L<Trog::Local>

=cut

1;
