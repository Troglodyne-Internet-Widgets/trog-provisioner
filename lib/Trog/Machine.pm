package Trog::Machine;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use File::Path();
use File::Basename();
use Path::Tiny();
use File::Copy();
use File::Temp();
use List::Util qw{any};
use File::Rsync();
use File::Slurper();
use IPC::Run3();
use File::Slurper::Temp();
use Net::OpenSSH::More();
use Time::HiRes qw{alarm};
use Trog::Credentials();
use Trog::Utils();
use Provisioner::Vars();

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

Takes C<host>, C<user>, C<port> and C<key_path>, all optional.  Subclasses
usually calculate these values from other data and pass them in.  The object
keeps every option that it is given.

=over 4

=item host - Str - the address to connect to

=item user - Str - the account to log in as

=item port - Int - the port of sshd, 22 by default

=item key_path - Str - the private key to log in with

=back

Returns a Trog::Machine object, of the class that it is called on.

    my $machine = Trog::Machine->new( host => '192.0.2.10', user => 'admin' );

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

=head2 keep($object), kept, forget

A class that keeps one object for the rest of the process keeps it here.
C<keep> keeps C<$object> as the one of the class it is called on.  C<kept>
returns that object.  C<forget> drops it, so that the next C<new> makes
another.  Call each as the class that keeps
the object: L<Trog::HV> keeps the hypervisor that the process talks to, and
L<Trog::Local> keeps the one object for this machine.  A class that keeps
nothing has nothing to forget.

=over 4

=item object - Trog::Machine - the object to keep

=back

Returns Trog::Machine or undef or 1: C<keep> returns C<$object>, C<kept> returns
the object that is kept, or undef, and C<forget> returns 1.

    Trog::Local->keep( Trog::Local->new );
    my $here = Trog::Local->kept;
    Trog::Local->forget;

=cut

# The one object of each class that keeps one, by that class.
my %KEPT;

sub keep   ( $class, $object ) { return $KEPT{$class} = $object }
sub kept   ($class)            { return $KEPT{$class} }
sub forget ($class)            { delete $KEPT{$class}; return 1 }

=head1 IDENTITY

=head2 ssh_host, ssh_user, ssh_port, ssh_key, ssh_target

Where to connect, and as which user.

Returns Str or undef: what went to C<new>, or undef when it was not given.
C<ssh_port> returns 22 when no port is set, as any other ssh client does.
C<ssh_target> returns C<user@host>, or only the host when no user is set, or
undef when no host is set.

    my @ssh = ( 'ssh', '-p', $machine->ssh_port, '-i', $machine->ssh_key, $machine->ssh_target );
    my ( $host, $user ) = ( $machine->ssh_host, $machine->ssh_user );

=head2 name

Returns the name of this machine in the configuration that it came from, a
Str, or undef when it has none.

    my $name = $machine->name // 'unnamed';

=head2 is_local

Returns 1 when this "machine" is the one we run on, and 0 when not, which is
the answer of this class.  Then each method below becomes a
plain local filesystem call or a C<system()> call.  A guest is never local.
L<Trog::Local> always is, and a hypervisor can be.

    my $where = $machine->is_local ? 'here' : $machine->ssh_target;

=head2 describe

Returns the name for this machine in an error message, a Str: its
C<ssh_target>, or "this machine".

    die 'Could not reach ' . $machine->describe . "\n";

=cut

sub ssh_host ($self) { return $self->{host} }
sub ssh_user ($self) { return $self->{user} }
sub ssh_port ($self) { return $self->{port} // 22 }
sub ssh_key  ($self) { return $self->{key_path} }
sub name     ($self) { return $self->{name} }
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

Returns the unprivileged account that the guest fetches as, a Str.  Locally,
that is the user that runs this tool.  On a remote machine, it is the login
user, or what C<id -un> says there, or undef when that says nothing.

    my $user = $machine->transfer_user;

=head2 authorized_keys

Returns the path of the C<authorized_keys> file of that account, a Str.  Dies
if it cannot find the home directory on a remote machine.

    my $file = $machine->authorized_keys;

=head2 sshd_port

Returns the port that the sshd of that machine listens on, an Int.  It comes from the sshd
configuration, not from the network, because several sshd instances can run at
once.  If no C<Port> line exists, it returns 22, which is the sshd default.  The
object keeps the result.

    my $port = $machine->sshd_port;

=cut

sub transfer_user {
    my ($self) = @_;
    return scalar getpwuid($<) if $self->is_local;
    return $self->ssh_user     if defined $self->ssh_user;

    my $who = $self->capture_cmd(qw{id -un});
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
    # The glob needs a shell, so sh expands it and perl does what tail and awk
    # did: the second word of the last line.
    my $said   = $self->capture_quiet( qw{sh -c}, q{grep -h '^Port ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf} ) // q{};
    my $last   = ( split m/\n/, $said )[-1]                                                                                // q{};
    my ($port) = $last =~ m/\A\s*Port\s+(\S+)/;

    # No Port line is the sshd default, not a failure, so it gets no warning on
    # every provision.
    return $self->{sshd_port} = ( $port || 22 );
}

=head1 THE CONNECTION

=head2 ssh

=over 4

=item %opts - the options of the constructor of L<Net::OpenSSH::More>

=back

Returns the L<Net::OpenSSH::More> connection.  It opens on first use and the
object keeps it.  Returns undef when the machine is us, because there is
nothing to connect to.  Dies if it cannot connect.

C<%opts> goes to the constructor.  So a caller that waits on a machine that is
still starting can increase C<retry_interval> and C<retry_max>.  Only the first
call can do this.  Every later call gets the existing connection and ignores its
options.

    my $ssh = $machine->ssh( retry_interval => 6, retry_max => 50 );

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

=head2 capture_cmd(@argv)

=over 4

=item @argv - Str - each word of the command, or one string for the shell

=back

Takes an argv list.  This module quotes the
arguments, so they can contain any character, a quote or a newline too.  A
single argument goes to the shell instead, and that is how you write a
pipeline.  Locally, a list goes to L<IPC::Run3> and a string goes to
C</bin/sh>.

Returns the standard output, a Str.  Locally, a command that cannot start gives
an empty string.

    my $kernel = $machine->capture_cmd(qw{uname -r});

=head2 capture_quiet(@argv)

=over 4

=item @argv - Str - each word of the command, or one string for the shell

=back

As C<capture_cmd>, and it throws standard error away, so that a command that
can fail does not print to the terminal of the caller.  It takes the place of
C<2E<gt>/dev/null>, which needs a shell.  Over ssh, the library hands back
standard error apart from the output, so there it is the same as C<capture_cmd>.  A command under sudo
can still carry its standard error in the output, because sudo can run it in a
pty.  For that, drop it inside sudo: C<< capture_sudo( qw{sh -c}, 'exec 2>/dev/null; exec cat "$1"', 'sh', $path ) >>.

Returns the standard output, a Str.

    my $said = $machine->capture_quiet( qw{systemctl is-active}, 'ssh' );

=head2 capture_sudo(@argv)

=over 4

=item @argv - Str - each word of the command

=back

Returns C<< $self->capture_cmd( qw{sudo -n}, @argv ) >>, a Str.  The C<-n> makes sudo
fail at once where it would ask for a password, so this never asks, and a
caller cannot leave the C<-n> out.  It returns standard output.
L</run_sudo(@argv)> returns the exit code, and it can ask.

    my $shadow = $machine->capture_sudo(qw{cat /etc/shadow});

=head2 capture_with_input($input, @argv)

=over 4

=item input - Str - what goes to standard input

=item @argv - Str - each word of the command

=back

Runs the argv list C<@argv> with C<$input> on its standard input.  The input can be as large as the
command reads: an argument has a limit of 128 KiB on Linux, and standard input
has none.  Over ssh, the command gets no terminal, because a terminal would
echo the input and break it into lines.  It runs under the alarm of the other
commands, and a C<sudo> that can ask is refused, as for C<capture_cmd>.

Returns the standard output and the standard error, two Str, as a list.

    my ( $out, $err ) = $machine->capture_with_input( $config, qw{sudo -n tee /etc/example.conf} );

=head2 run_cmd(@argv)

=over 4

=item @argv - Str - each word of the command, or one string for the shell

=back

Takes an argv list.  This module escapes the
arguments, so they can contain any character.  A single argument goes to the
shell of the far side instead, and that is how you write a pipeline.

On a remote machine, both run their command with C<SYSTEMD_PAGER> and
C<PAGER> set to C<cat>, as C<unpaged> writes it.  L<Net::OpenSSH::More> gives
each of these commands a terminal, and on a terminal C<systemctl>,
C<journalctl> and C<git> start a pager, which waits for a key that nobody
presses.  A command under C<sudo> loses both, because sudo resets the
environment, so it passes C<--no-pager> itself.

These names say what the methods do.  They are not C<run> and C<capture>,
because Perl::Critic::Policy::PreferredBinaries reads those names as local
runners.  These methods run their command on whatever machine this is.  That is
usually another machine, where advice to use a perl module does not apply.

On a remote machine, each of these, and every other command below, runs under a
SIGALRM.  So a hung call becomes an error with a name, and the tool does not
wait forever.  The call dies with "Gave up on" when the alarm fires.  The limit
is what C<hang_limit> returns for the command.

The library's own C<timeout> stops a call that only stalls, and it acts first.
This alarm is for a case that the library cannot see: a call that stops making
progress while the connection seems fine.  sftp does this when the far side
refuses a write.  In normal use, nothing reaches this alarm.

On a remote machine, both die before they send a command that starts with
C<sudo> and not with C<sudo -n>, or C<sudo -V>, which asks for nothing and
refuses C<-n>.  Such a sudo asks for a password when the
login user has no grant for the command.  Nobody can type one over this
connection, so the command waits until the alarm, and says nothing about sudo.
C<sudo -n> fails at once instead, and L</run_sudo(@argv)> can give a password.
Only the first word is checked.  A sudo later in a pipeline is the business of
its caller.

Returns the exit code, an Int.

    my $rc = $machine->run_cmd( qw{test -d}, '/opt/domains' );

=head2 Trog::Machine::hang_limit($what)

=over 4

=item what - Str|Undef - the command, as one string

=back

Returns how many seconds, an Int, the command C<$what> can run on a remote machine before it
counts as hung.  That is C<$HANG_TIMEOUT>, or the command's own C<timeout> plus
60 seconds if that is longer.  Undef gives C<$HANG_TIMEOUT>.

A command that blocks for a long time on purpose, such as the wait of
L<Trog::Guest> for the Makefile of a guest, must say so with C<timeout>.  Its
own limit then decides, and the alarm does not stop it early.

    my $seconds = Trog::Machine::hang_limit('sudo -n timeout 90m make');

=cut

sub hang_limit ($what) {
    return $HANG_TIMEOUT unless defined $what;

    my %seconds = ( '' => 1, s => 1, m => 60, h => 3600, d => $Provisioner::Vars::SECONDS_A_DAY );
    my $limit   = $HANG_TIMEOUT;

    while ( $what =~ m/\btimeout\s+(\d+)([smhd]?)\b/g ) {
        my $own = $1 * $seconds{ $2 // '' };
        $limit = $own + 60 if $own + 60 > $limit;
    }

    return $limit;
}

# Runs $code, which talks to the far side, under the alarm that RUNNING THINGS
# describes, and returns what $code returns.  $what names the command in the
# error and sets the limit.  Locally, it runs $code with no alarm.
my sub unhang ( $self, $what, $code ) {
    return $code->() if $self->is_local;

    my $limit = hang_limit($what);

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

# Dies if $what, a command for the far side as one string, starts with a sudo
# that can ask for a password.  See capture_cmd(@argv).
my sub refuse_asking_sudo ( $self, $what ) {
    return if $what !~ m/\A\s*sudo\s/ || $what =~ m/\A\s*sudo\s+-[nV](?:\s|\z)/;
    die "Refusing to send '$what' to " . $self->describe . ": over ssh, nobody can type the password that sudo would ask for, so it would wait until the alarm.\n" . "Write sudo -n, which fails at once instead, or use run_sudo, which can give a password.\n";
}

=head2 Trog::Machine::unpaged(@command)

=over 4

=item @command - Str - each word of the command, or one string for the shell

=back

Returns C<@command> as C<capture_cmd> and C<run_cmd> send it to the far side,
with no pager: C<SYSTEMD_PAGER> and C<PAGER> set to C<cat>.  A single argument is a
string for the shell of the far side, so the variables are exported in front
of it, and a pipeline sees them too.  A list gets C<env> in front.  So it
returns one Str for one argument, and a list of Str for a list.

    my @argv = Trog::Machine::unpaged(qw{systemctl status ssh});

=cut

our @NO_PAGER = qw{SYSTEMD_PAGER=cat PAGER=cat};

sub unpaged (@command) {
    return "export @NO_PAGER; $command[0]" if @command == 1;
    return ( 'env', @NO_PAGER, @command );
}

# Runs @argv and returns its standard output.  $quiet drops standard error: a
# local command gets it discarded, and over ssh it is already kept apart from
# the output, so a remote call needs nothing.  A single argument is a shell
# string, and more than one is an argv list that nothing parses again.
my sub capture ( $self, $quiet, @argv ) {
    my $cmd = @argv == 1 ? $argv[0] : \@argv;
    if ( $self->is_local ) {

        # A string still goes to a shell, as documented, because callers write
        # pipelines.  run3 closes stdin, so a command that reads stdin cannot
        # wait on a terminal that is busy elsewhere.
        #
        # A list has no shell to say "not found" for a program that is not
        # there, and run3 dies instead.  The shell form gave an empty answer
        # for that, as does a remote machine, so a caller that tests for a
        # tool by running it needs the same here.
        my $out;
        my $ran = eval { IPC::Run3::run3( $cmd, \undef, \$out, ( $quiet ? \undef : undef ) ); 1 };
        return $ran ? $out : q{};
    }

    my $what = join( ' ', @argv );
    refuse_asking_sudo( $self, $what );
    return unhang( $self, $what, sub { ( $self->ssh->cmd( unpaged(@argv) ) )[0] } );
}

sub capture_cmd ( $self, @argv ) { return capture( $self, 0, @argv ) }

sub capture_quiet ( $self, @argv ) { return capture( $self, 1, @argv ) }

sub capture_sudo ( $self, @argv ) { return $self->capture_cmd( qw{sudo -n}, @argv ) }

sub capture_with_input ( $self, $input, @argv ) {
    if ( $self->is_local ) {
        IPC::Run3::run3( \@argv, \$input, \my $out, \my $err );
        return ( $out // q{}, $err // q{} );
    }

    my $what = join( ' ', @argv );
    refuse_asking_sudo( $self, $what );
    return unhang( $self, $what, sub { $self->ssh->capture2( { timeout => $TIMEOUT, stdin_data => $input }, @argv ) } );
}

sub run_cmd {
    my ( $self, @argv ) = @_;
    return system(@argv) >> 8 if $self->is_local;

    my $what = join( ' ', @argv );
    refuse_asking_sudo( $self, $what );
    return unhang( $self, $what, sub { $self->ssh->cmd_exit_code( unpaged(@argv) ) } );
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

Returns the password kept for this machine, a Str, or undef if we did not ask
for one.  The key
is the target of the machine, so two objects for the same host share it and
nobody is asked twice.

    my $asked = defined $machine->sudo_password;

=cut

my %SUDO_PASSWORD;

# The key under which %SUDO_PASSWORD keeps the password of this machine.
my sub sudo_key ($self) { return $self->ssh_target // 'localhost' }

sub sudo_password {
    my ($self) = @_;
    return $SUDO_PASSWORD{ sudo_key($self) };
}

=head2 forget_sudo_passwords

Clears every kept password.  Only the tests use this.

Returns 1.

    Trog::Machine->forget_sudo_passwords;

=cut

sub forget_sudo_passwords { %SUDO_PASSWORD = (); return 1 }

# What sudo prints when it needs a password that it cannot ask for.
our @WANTS_PASSWORD = ( 'sudo: a password is required', 'sudo: password is required', 'sudo: a terminal is required', 'sudo: no password was provided' );

=head2 run_sudo(@argv)

=over 4

=item @argv - Str - each word of the command

=back

Runs C<@argv> as root, and asks for a password if the far side needs one.

Returns the exit code, an Int, like C<run_cmd>.  Dies if it cannot ask for a password,
or after three wrong ones.

The password is the one given to L<Trog::Credentials> before the run, under the
name C<sudo>.  Without one, it asks at the terminal through
C<< Trog::Credentials->prompt >>, and dies with what to configure when there is
no terminal.  Dies if the answer is empty.

    my $rc = $machine->run_sudo( qw{systemctl restart}, 'ssh' );

=head2 run_sudo_or_die(@argv)

=over 4

=item @argv - Str - each word of the command

=back

Runs C<@argv> as C<run_sudo> does.

Returns 1.  Dies, naming the command and the machine, unless it exits 0, and for
each reason that C<run_sudo> dies.

    $machine->run_sudo_or_die( qw{systemctl restart}, 'ssh' );

=cut

sub run_sudo {
    my ( $self, @argv ) = @_;

    # A local sudo can ask at our own terminal.
    return $self->run_cmd( 'sudo', @argv ) if $self->is_local;

    # The first go is with the password we have, if any.  Three tries, then stop.
    foreach my $attempt ( 0 .. 3 ) {
        my $password = $self->sudo_password;
        my @sudo     = defined $password ? ( qw{sudo -S -p}, q{} )         : (qw{sudo -n});
        my %stdin    = defined $password ? ( stdin_data => "$password\n" ) : ();

        my ( $out, $err ) = unhang(
            $self,
            join( ' ', 'sudo', @argv ),
            sub {
                $self->ssh->capture2( { timeout => $TIMEOUT, %stdin }, @sudo, @argv );
            }
        );
        my $rc = $? >> 8;
        return 0 unless $rc;

        my $said  = ( $out // '' ) . ( $err // '' );
        my $wrong = $said =~ m/sudo:\s\d+\sincorrect\spassword\sattempt|Sorry,\stry\sagain/;
        my $wants = any { index( $said, $_ ) >= 0 } @WANTS_PASSWORD;
        return $rc unless $wrong || $wants;
        last if $attempt == 3;

        if ($wrong) {

            # Not warn: this is part of a password prompt, and a source location in it
            # is noise to somebody who is typing the password again.
            print {*STDERR} "Sorry, try again.\n";    ## no critic (ProhibitPrintSTDERR)
            delete $SUDO_PASSWORD{ sudo_key($self) };
        }

        # Given before the run, by a caller that has nobody to ask.
        if ( Trog::Credentials->have('sudo') ) {
            $SUDO_PASSWORD{ sudo_key($self) } = Trog::Credentials->get('sudo');
            next;
        }

        # Ask at the terminal, not on stdin, because cron and redirected runs
        # point stdin where nobody types.
        my $typed;
        eval {
            $typed = Trog::Credentials->prompt( '[sudo] password for ' . ( $self->ssh_user // 'you' ) . ' on ' . $self->describe . ':', 'sudo', terminal => 1 );
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

        die 'No password given for ' . $self->describe . "\n" unless length $typed;    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a password of "0" is still a password

        $SUDO_PASSWORD{ sudo_key($self) } = $typed;
    }

    die 'Could not authenticate sudo on ' . $self->describe . "\n";
}

sub run_sudo_or_die ( $self, @argv ) {
    $self->run_sudo(@argv) == 0 or die 'Could not run ' . join( ' ', @argv ) . ' on ' . $self->describe . "\n";
    return 1;
}

=head1 FILES

Each of these is the plain local filesystem call when the machine is us, and a
command over the connection when it is not.  The C<sudo> option on the writers
is for destinations that the login user does not own, such as anything under
C</etc>, C</usr> or C</root>.  With C<sudo>, C<mode> sets the permissions of the
result, and the default is 0644.  The chmod is necessary because a staging file
from C<mktemp> is 0600, and a local copy through sudo gets the umask of root.  A
write without C<sudo> leaves the mode to the writer.

=cut

# Runs @cmd on the far side with the options of Net::OpenSSH's system in
# \%opts.  Returns 1 on success, and warns and returns 0 on failure.
my sub remote_system ( $self, $opts, @cmd ) {
    my $ok = unhang(
        $self,
        join( ' ', @cmd ),
        sub { $self->ssh->system( { timeout => $TIMEOUT, %$opts }, @cmd ) }
    );

    warn 'Remote ' . join( ' ', @cmd ) . ' failed: ' . ( $self->ssh->error // 'unknown' ) . "\n" unless $ok;
    return $ok ? 1 : 0;
}

# Writes a stream to $path on the far side.  \%stdin holds stdin_data or
# stdin_file.  Takes append, sudo and mode.  Returns 1 on success and 0 on
# failure.
my sub pour ( $self, $stdin, $path, %opts ) {
    unless ( $opts{sudo} ) {
        return remote_system( $self, { %$stdin, stdout_discard => 1 }, ( $opts{append} ? qw{tee -a} : 'tee' ), $path );
    }

    # A privileged write is always two commands, because the content and the
    # sudo password both need standard input.  See SUDO.  mktemp makes the
    # staging file on the far side, in a directory that exists and we can write.
    my $staged = $self->capture_cmd('mktemp');
    chomp $staged if defined $staged;
    unless ( $staged && $staged =~ m{\A/} ) {
        warn 'Could not make a staging file on ' . $self->describe . "\n";
        return 0;
    }
    unless ( remote_system( $self, { %$stdin, stdout_discard => 1 }, 'tee', $staged ) ) {
        $self->remove($staged);
        return 0;
    }

    my $ok;
    if ( $opts{append} ) {

        # A move would replace the file, so sudo sh -c concatenates the staged
        # content onto it.  >> has no argv form, so the command is one string.
        $ok = !$self->run_sudo( qw{sh -c}, sprintf( 'cat %s >> %s', Trog::Utils::shell_quote($staged), Trog::Utils::shell_quote($path) ) );
        $self->remove($staged);
    }
    else {
        $ok =
             !$self->run_sudo( 'mv',    $staged,               $path )
          && !$self->run_sudo( 'chown', 'root:root',           $path )
          && !$self->run_sudo( 'chmod', $opts{mode} // '0644', $path );
        $self->remove($staged) unless $ok;
    }

    return $ok ? 1 : 0;
}

# Whether C<$path> is a plain file.
# @param   path  Str  the path to test
# @returns Bool  1 if C<$path> is a plain file, and 0 if not
# @example print "there\n" if $machine->file_exists('/etc/hostname');
sub file_exists {
    my ( $self, $path ) = @_;
    return -f $path                                  ? 1 : 0 if $self->is_local;    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- the question test -f asks of a remote machine
    return $self->run_cmd( qw{test -f}, $path ) == 0 ? 1 : 0;
}

# Whether C<$path> is a directory.  It follows a symlink, as C<test> does.
# @param   path  Str  the path to test
# @returns Bool  1 if C<$path> is a directory, and 0 if not
# @example print "there\n" if $machine->is_dir('/opt/domains');
sub is_dir ( $self, $path ) {
    return -d $path                                  ? 1 : 0 if $self->is_local;
    return $self->run_cmd( qw{test -d}, $path ) == 0 ? 1 : 0;
}

# Whether C<$path> is a block device.  It follows a symlink, as C<test> does.
# @param   path  Str  the path to test
# @returns Bool  1 if C<$path> is a block device, and 0 if not
# @example print "a disk\n" if $machine->is_block_device('/dev/vda');
sub is_block_device ( $self, $path ) {
    return -b $path                                  ? 1 : 0 if $self->is_local;
    return $self->run_cmd( qw{test -b}, $path ) == 0 ? 1 : 0;
}

# Makes each directory and its parents.  On a remote machine, if the login user
# cannot make one, it uses C<sudo> and gives the directory to the login user.
# @param   @paths  Str  each directory to make
# @returns Bool  1, or 0 when a C<sudo> to make a directory fails
# @throws  when C<sudo> cannot ask for a password, as C<run_sudo> does
# @example $machine->mkpath('/opt/domains/vm.test.test') or die "Could not make it\n";
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
        my $user = $self->ssh_user // $self->capture_cmd(qw{id -un});
        chomp $user if defined $user;
        return 0    if $self->run_sudo( qw{mkdir -p}, $path );
        $self->run_sudo( 'chown', "$user:", $path );
    }
    return 1;
}

# Deletes each file.
# @param   @paths  Str  each file to delete
# @returns Bool  true when the files are gone, false when C<rm> failed
# @example $machine->remove('/tmp/setup.sh');
sub remove {
    my ( $self, @paths ) = @_;
    if ( $self->is_local ) {
        unlink @paths;
        return 1;
    }
    return $self->run_cmd( qw{rm -f}, @paths ) == 0;
}

# Deletes each directory and everything under it.
# @param   @paths  Str  each directory to delete
# @returns Bool  true when the trees are gone, false when C<rm> failed
# @example $machine->remove_tree('/opt/domains/vm.test.test');
sub remove_tree {
    my ( $self, @paths ) = @_;
    if ( $self->is_local ) {
        File::Path::remove_tree(@paths);
        return 1;
    }
    return $self->run_cmd( qw{rm -rf}, @paths ) == 0;
}

# The names in a directory, with no path and no dotfiles.  The callers ask
# what is left in a place, and "nothing" is a valid answer.
# @param   path  Str  the directory
# @returns Str  each name, sorted when the machine is us, as a list; an empty
#   list for a directory that does not exist, as C<glob> does
# @example my @names = $machine->list_dir('/opt/domains');
sub list_dir {
    my ( $self, $path ) = @_;
    if ( $self->is_local ) {
        return () unless -d $path;
        my @names = sort map { local ($_) = $_; $_->basename } Path::Tiny::path($path)->children(qr/\A[^.]/);
        return @names;
    }

    # ls, not sftp.  See "Why none of this uses sftp".
    my $listing = $self->capture_quiet( qw{ls -1}, $path ) // '';
    return grep { $_ } split( m/\n/, $listing );
}

# The content of a file.
# @param   path  Str  the file to read
# @returns Str|Undef  the content; on a remote machine, undef if the read fails
# @throws  when the machine is us and the read fails
# @example my $text = $machine->read_text('/etc/hostname');
sub read_text {
    my ( $self, $path ) = @_;
    return File::Slurper::read_text($path) if $self->is_local;

    # capture(), not cmd(): cmd chomps, and the trailing newline is part of the
    # file.
    #
    # Scalar context, explicitly.  unhang calls its code in list context and
    # gives a scalar caller the first element, and capture in list context
    # returns one element per line.
    #
    # The exit status decides, not $ssh->error.  That error is sticky: it holds
    # the last error from anything on this connection.  So an earlier failure on
    # purpose, such as the sudo -n probe, makes a good cat look like a failure.
    my $content = unhang(
        $self,
        "cat $path",
        sub { scalar $self->ssh->capture( { timeout => $TIMEOUT }, 'cat', $path ) }
    );

    return $? >> 8 ? undef : $content;
}

# Writes C<$content> to C<$path>.  See L</FILES> for C<sudo> and C<mode>.
# @param   path     Str  the file to write
# @param   content  Str  what to write
# @param   sudo     Bool  write it as root
# @param   mode     Str  the mode of the file with C<sudo>, C<0644> by default
# @returns Bool  1 on success and 0 on failure
# @throws  when the machine is us, without C<sudo>, and the write fails
# @example $machine->write_text( '/etc/motd', "Built by trog-provisioner\n", sudo => 1, mode => '0644' );
sub write_text {
    my ( $self, $path, $content, %opts ) = @_;
    return pour( $self, { stdin_data => $content }, $path, %opts ) unless $self->is_local;

    # The write itself is the test of access.  A -w test describes a moment that
    # is already past.  It also cannot see an immutable bit, a full disk or a
    # read-only mount.
    return 1 if eval { File::Slurper::Temp::write_text( $path, $content ); 1 };
    die $@ unless $opts{sudo};

    my $tmp = File::Temp->new( UNLINK => 1 );
    print {$tmp} $content;
    close($tmp) or die "Could not close $tmp: $!";
    my $ok = $self->run_sudo( qw{cp}, "$tmp", $path ) == 0;
    $self->run_sudo( 'chmod', ( $opts{mode} // '0644' ), $path ) if $ok;
    return $ok ? 1 : 0;
}

# Copies one file from here to there.  See L</FILES> for C<sudo> and C<mode>.
# @param   local   Str  the file here
# @param   remote  Str  the path there
# @param   sudo    Bool  write it as root
# @param   mode    Str  the mode of the file with C<sudo>, C<0644> by default
# @returns Bool  1 on success and 0 on failure
# @example $machine->put_file( 'setup.sh', '/root/setup.sh', sudo => 1, mode => '0755' );
sub put_file {
    my ( $self, $local, $remote, %opts ) = @_;

    if ( $self->is_local ) {

        # Copy it ourselves if we can, and use sudo only if that fails.
        return 1 if File::Copy::copy( $local, $remote );
        return 0 unless $opts{sudo};
        return 0 if $self->run_sudo( qw{cp}, $local, $remote );
        return $self->run_sudo( 'chmod', ( $opts{mode} // '0644' ), $remote ) == 0 ? 1 : 0;
    }

    return pour( $self, { stdin_file => $local }, $remote, %opts );
}

# Copies a whole directory tree from that machine to here.  It is incremental: a
# file that is already here and did not change does not travel again.  See
# L</Why a directory comes over rsync>.  Prints the total size transferred.
#
# rsync is a local process, not a command down the connection, so it does not run
# under the alarm of L</RUNNING THINGS>.  That limit is wall-clock time, and it
# would stop a long data transfer at exactly C<$HANG_TIMEOUT>, however well it
# went.  The C<--timeout> of rsync measures silence, not elapsed time.  So a
# transfer that keeps moving has as long as it needs, and one that stops ends.
#
# The patterns of C<exclude> in use come from C<remote_skip> in
# L<Provisioner::Recipe>.
#
# C<sudo> runs the far end as root, for a tree that the login user cannot read.  A
# service keeps its state in a directory that only it can open.  An unprivileged
# fetch of that directory walks the tree, makes the local directories, copies no
# files, and exits with success.  That looks the same as a guest with no state.
# C<sudo> needs passwordless sudo on the far side, and without it the fetch fails
# and does not wait.
#
# Without C<deleted_to>, nothing is deleted here.  With it, our copy mirrors the
# far side: a file that is gone there leaves our copy as well.  It is not
# removed.  It moves into the directory that C<deleted_to> names, at the same
# relative path.  The copy that C<get_dir> writes into is the only copy, so that
# directory is the history that a mirror needs.
#
# A dry run of rsync with C<--delete> lists what to move, before the fetch.  So
# only deleted files are kept: rsync's own C<--backup> would also keep each file
# that a run overwrites, and a salvage overwrites every database that changed.
# rsync lists no deletions on a run that had an I/O error, so a run that could not
# read part of the far side moves nothing.  If the dry run fails, nothing moves,
# and the fetch runs as without C<deleted_to>.  A path that C<exclude> names is
# neither fetched nor moved.
#
# The files that arrive belong to the user that runs this tool, not to the uids
# that they had on the guest.  rsync restores ownership only when the
# B<receiving> end is root, and this end is not.  C<scripts/restore_state> puts
# the files back as the user that the service runs as.  The caller gives it that
# owner.
# @param   remote      Str  the directory there
# @param   local       Str  the directory here, made if it is not there
# @param   exclude     ArrayRef[Str]  rsync patterns for paths that must not come down
# @param   update      Bool  keep our copy of a file when it is the newer one
# @param   sudo        Bool  run the far end as root
# @param   deleted_to  Str  an absolute path outside C<$local>, where a file that the
#   far side no longer has moves to
# @returns Bool  1 on success; on failure, it warns with the rsync errors and
#   returns 0
# @example $machine->get_dir( '/var/lib/example', "$data_dir/example", exclude => ['*.sock'], sudo => 1 );
sub get_dir {
    my ( $self, $remote, $local, %opts ) = @_;

    # Local whichever machine this is, because the destination of a fetch is us.
    # rsync creates only the last component of a destination, and a salvage goes
    # two or three levels down in a data directory that can be new this run.
    File::Path::make_path($local);

    # The trailing slash tells rsync "the contents of this", not "this, inside
    # that".
    my $src  = ( $self->is_local ? q{} : $self->ssh_target . ':' ) . "$remote/";
    my $dest = "$local/";

    # The port and the key, which reach rsync from nowhere else, and any host
    # key, as Net::OpenSSH::More accepts, because a rebuilt guest has a new one.
    # rsync splits this on spaces, which no key path that this tool writes has.
    my @rsh = (
        'ssh', '-p', $self->ssh_port,
        '-o' => 'StrictHostKeyChecking=no',
        '-o' => 'UserKnownHostsFile=/dev/null',
        '-o' => 'GSSAPIAuthentication=no',
        '-o' => 'ConnectTimeout=180',
        ( defined $self->ssh_key ? ( '-i', $self->ssh_key ) : () ),
    );
    my @exclude = @{ $opts{exclude} // [] };

    my %reach = (
        archive => 1,
        timeout => $TIMEOUT,

        ( $self->is_local ? ()                       : ( rsh => join( ' ', @rsh ) ) ),
        ( @exclude        ? ( exclude => \@exclude ) : () ),

        # sudo -n, because no terminal at the far end can answer a password
        # prompt.  -n exits, and rsync reports the failure.
        ( $opts{sudo} ? ( 'rsync-path' => 'sudo -n rsync' ) : () ),
    );

    # Before the fetch, a dry run with --delete names what the far side no
    # longer has, and each of those files moves into deleted_to.
    my $deleted_to = $opts{deleted_to};
    my $dry        = defined $deleted_to ? File::Rsync->new( %reach, 'dry-run' => 1, delete => 1, 'itemize-changes' => 1 ) : undef;
    if ( $dry && !$dry->exec( src => $src, dest => $dest ) ) {
        warn "rsync $src -> $dest could not list what the far side no longer has, so nothing is set aside:\n" . join( '', map { "    $_" } @{ $dry->err || [] } );
        $dry = undef;
    }
    if ($dry) {
        my @lines = @{ $dry->out || [] };
        chomp @lines;

        # rsync names a path relative to $dest, and a directory with a slash at
        # the end.  A path that climbs out of $dest is refused, whatever
        # printed it.
        my @gone  = grep { !m{(?:\A|/)[.][.](?:/|\z)} && !m{\A/} } map { m/\A[*]deleting\s+(.+)\z/ ? $1 : () } @lines;
        my @dirs  = grep { m{/\z} } @gone;
        my @files = grep { !m{/\z} } @gone;

        my $set_aside = 0;
        foreach my $file (@files) {
            my ( $from, $to ) = ( "$dest$file", "$deleted_to/$file" );
            next unless -e $from || -l $from;
            File::Path::make_path( File::Basename::dirname($to) );

            # rename fails across filesystems.  File::Copy::move copies a file
            # there, but it copies the target of a symlink, so a symlink is
            # made again.
            my $ok =
                rename( $from, $to ) ? 1
              : -l $from             ? symlink( readlink($from) // q{}, $to ) && unlink($from)
              :                        File::Copy::move( $from, $to );
            if ($ok) {
                $set_aside++;
                next;
            }
            warn "Could not move $from, which the far side no longer has, to $to: $!\n";
        }

        # Deepest first, so that a parent is empty when its turn comes.  A
        # directory that still holds a file, such as an excluded one, stays.
        rmdir("$dest$_") foreach reverse sort { length($a) <=> length($b) } @dirs;

        print "Set aside $set_aside files that the far side no longer has, in $deleted_to\n" if $set_aside;
    }

    my $rsync = File::Rsync->new(
        %reach,

        # Report what moved, so that an unchanged tree says so.  Human units,
        # because that number is usually in gigabytes.
        stats            => 1,
        'human-readable' => 1,

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

# Appends a line, but only if the file does not already contain it.  It makes
# the directory of the file first.
# @param   path  Str  the file
# @param   line  Str  the line, with or without its newline
# @returns Bool  1 when the file holds the line, or 0 when a remote write failed
# @throws  when the machine is us and the file cannot be opened or closed
# @example $machine->append_line( "$home/.ssh/authorized_keys", $pubkey );
sub append_line {
    my ( $self, $path, $line ) = @_;
    chomp $line;

    # Append, never read-modify-write.  This is often an authorized_keys file,
    # and a rewrite after an empty read leaves one key and locks its owner out.
    $self->mkpath( $path =~ s{/[^/]*\z}{}r || '/' );

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

    return pour( $self, { stdin_data => "$line\n" }, $path, append => 1 );
}

# What root reads in C<$path>, through C<sudo -n cat>, without its last newline.
# So a caller that writes from what it read uses C<rewrite_lines>, which tells the
# empty answers apart.
# @param   path  Str  the file
# @returns Str  the text; an empty string when root reads nothing there, which is
#   also the answer for a file that is not there and for a read that failed
# @example my $hosts = $machine->root_text('/etc/hosts');
sub root_text ( $self, $path ) {

    # The redirect is inside sudo, because sudo can run the command in a pty
    # that carries its standard error along with its standard output, and the
    # complaint of cat about a missing file is not the text of the file.
    my $text = $self->capture_sudo( qw{sh -c}, 'exec 2>/dev/null; exec cat "$1"', 'sh', $path ) // q{};
    chomp $text;
    return $text;
}

# Whether root reads C<$line>, as a whole line, in C<$path>.
# @param   path  Str  the file
# @param   line  Str  the line, without its newline
# @returns Bool  true when the file holds the line
# @example print "set\n" if $machine->holds_line( '/etc/hosts', '192.0.2.10 vm.test.test' );
sub holds_line ( $self, $path, $line ) {
    return any { $_ eq $line } split m/\n/, $self->root_text($path);
}

# Writes C<$path> as root.  It keeps each line of the file for which C<keep>
# returns true, in their order, and then puts each line of C<add>.
# @param   path  Str  the file
# @param   keep  CodeRef  gets a line and returns true to keep it; without it,
#   every line is kept
# @param   add   ArrayRef[Str]  the lines to put after the kept ones
# @param   mode  Str  the mode of the file, C<0644> by default
# @returns Int  1
# @throws  when the read comes back empty but the file is not empty, and then it
#   writes nothing.  A write from that read would drop every line that somebody
#   else put there.
# @throws  when the write fails
# @example $machine->rewrite_lines( '/etc/hosts', keep => sub ($line) { $line !~ m/test[.]test/ }, add => ['192.0.2.10 vm.test.test'] );
sub rewrite_lines ( $self, $path, %opts ) {
    my $keep = $opts{keep} // sub ($line) { 1 };
    my $text = $self->root_text($path);
    die "Could not read $path on " . $self->describe . "; refusing to rewrite it blind\n"
      if $text eq q{} && $self->run_cmd( qw{sudo -n test -s}, $path ) == 0;

    my @lines = ( ( grep { local ($_) = $_; $keep->($_) } split m/\n/, $text ), @{ $opts{add} // [] } );
    $self->write_text( $path, join( q{}, map { "$_\n" } @lines ), sudo => 1, mode => $opts{mode} // '0644' )
      or die "Could not write $path on " . $self->describe . "\n";
    return 1;
}

=head1 SEE ALSO

L<Trog::HV>, L<Trog::Guest>, L<Trog::Local>

=cut

1;
