package Trog::Guest;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';
use parent 'Trog::Machine';

use File::Slurper();
use File::Temp();
use Net::EmptyPort();
use JSON::MaybeXS();
use Trog::Config();
use Trog::Credentials();
use Trog::Secrets();

=head1 NAME

Trog::Guest - a VM that was just built, and the waits until it is ready

=head1 SYNOPSIS

    use Trog::Guest();

    my $domain = 'vm.example.test';

    my $guest = Trog::Guest->new(
        name     => $domain,
        host     => '203.0.113.10',
        user     => 'ubuntu',
        key_path => "/opt/domains/$domain/key.rsa",
    );

    $guest->wait_for_ssh() or die "$domain never came up";
    $guest->put_file('setup.sh', "/root/setup-$domain.sh", sudo => 1, mode => '0755');
    $guest->wait_for_cloud_init();
    $guest->wait_for_makefile();

=head1 DESCRIPTION

The other end of the job from L<Trog::HV>.  A hypervisor makes the machine,
and this class waits for it.  L<Trog::Machine> owns the connection, the
commands and the file transfers, and says why none of them use sftp.

A new guest is not ready for its first few minutes, in several separate ways.
Each way needs a different check, and each check is a method here.

=head1 CLASS METHODS

=head2 new(%opts)

Takes C<host>, C<user>, C<key_path> and C<name>.  C<name> is what messages call
this guest.  Dies when C<host> is missing.  The others are optional, but a
connection nearly always needs C<user> and C<key_path>.

=cut

# How long to wait for things a guest does only once, on first boot.
our $BOOT_TIMEOUT = 300;

# Seconds between connection attempts, the default of Net::OpenSSH::More.
# Named here because wait_for_ssh divides the boot timeout by it.
our $SSH_RETRY_INTERVAL = 6;

# The whole Makefile runs inside this timeout, not only the waits.  The first
# wait is on the at queue, and the job stays there for the whole build.  The
# longest build installs perl from source and ninety-odd distributions after it.
# It takes about twenty minutes.
#
# Trog::Machine::_unhang must allow at least this long, or it treats a guest
# that is still building as hung.  It reads its limit from each command.
our $SETUP_TIMEOUT = $ENV{TROG_SETUP_TIMEOUT} || '90m';

# The build writes the status file as make exits, so it exists when the log
# closes.  A missing file does not come later, so a longer wait only hangs.
our $STATUS_GRACE = '60s';

sub new {
    my ( $class, %opts ) = @_;

    die "A guest needs a host to connect to\n" unless $opts{host};
    return $class->SUPER::new(%opts);
}

=head1 IDENTITY

=head2 name

Returns the name that messages use for this guest, or its address when it has
no name.

=head2 describe

Returns C<name (user@host)> when the guest has a name, and C<user@host> when it
does not.  With no C<user>, the address is only the host.

=cut

sub name ($self) { return $self->{name} // $self->ssh_host }

sub describe {
    my ($self) = @_;
    my $target = $self->ssh_target;
    return defined $self->{name} ? "$self->{name} ($target)" : $target;
}

=head1 WAITING

=head2 wait_for_ssh(%opts)

Waits until an SSH connection to the guest opens, and returns the guest.  Takes
C<timeout> in seconds, default 300.

Two things must be true.  The port must be open, I<and> the connection must
succeed.  A VM that listens but does not yet accept our key is of no use.  A
check of the port alone gives a confusing failure three steps later.

Dies when the port does not open within C<timeout>, or when the connection does
not open in about the same time.

=cut

sub wait_for_ssh {
    my ( $self, %opts ) = @_;
    my $timeout = $opts{timeout} // $BOOT_TIMEOUT;

    print 'Waiting for ' . $self->ssh_host . ":22 to come live...\n";
    Net::EmptyPort::wait_port( { host => $self->ssh_host, port => 22, max_wait => $timeout } )
      or die 'SSH port on ' . $self->describe . " never came up after ${timeout}s\n";

    # The same window as the port, not the one minute of the library.  sshd
    # answers long before cloud-init writes authorized_keys, and ssh-import-id
    # fetches some of those keys from GitHub.  Until then the guest answers
    # "Permission denied".  The library does not retry a refusal by default,
    # because each retry offers every key in the agent again.  A host that
    # counts failed logins bans you for that.  Here a refusal is the normal
    # state of a machine that is still being built.
    $self->ssh(
        retry_interval        => $SSH_RETRY_INTERVAL,
        retry_max             => int( $timeout / $SSH_RETRY_INTERVAL ) || 1,
        retry_on_auth_failure => 1,
    ) or die 'Could not establish an SSH connection to ' . $self->describe . "\n";
    return $self;
}

=head2 wait_for_cloud_init($domain, %opts)

Waits for cloud-init to finish, then makes sure that it told the truth.
C<$domain> defaults to L</name>.  Takes C<timeout>, default C<$SETUP_TIMEOUT>.
Returns 1.

The wait ends when F</var/log/cloud-init-output.log> says C<Boot configuration
complete.>  cloud-init can say that after a run in which some modules failed.
So this then reads C<cloud-init analyze dump>, and runs again each module that
came back C<FAIL>.  It first removes the semaphore of that module, because
otherwise cloud-init does not run it a second time.

Dies when the wait fails or times out, or when C<cloud-init analyze dump> does
not return a JSON array.

=cut

sub wait_for_cloud_init {
    my ( $self, $domain, %opts ) = @_;
    my $timeout = $opts{timeout} // $SETUP_TIMEOUT;
    $domain //= $self->name;

    print "Waiting up to $timeout for Cloud-init to finish...\n";
    my $rc = $self->run_cmd(qq{sudo timeout $timeout bash -c 'until grep "Boot configuration complete." /var/log/cloud-init-output.log; do sleep 1; done;'});
    print "Done!\n";
    die 'Cloud init reported failure on ' . $self->describe . ", investigate the machine\n" if $rc;

    my $raw    = $self->capture_cmd('sudo cloud-init analyze dump');
    my $parsed = eval { JSON::MaybeXS->new( utf8 => 1 )->decode($raw) };
    die "cloud-init analyze dump on " . $self->describe . " did not return a JSON array\n"
      unless ref $parsed eq 'ARRAY';

    foreach my $fail ( grep { ( $_->{result} // '' ) eq 'FAIL' } @$parsed ) {
        my ( undef, $mtarget ) = split( m{/}, $fail->{name} );
        next unless $mtarget;
        my ( $stage, $target ) = split( m/-/, $mtarget );
        next unless $target;

        print "$target failed during $stage, re-running...\n";
        $self->run_sudo( qw{rm}, "/var/lib/cloud/instances/$domain/sem/$stage\_$target" );
        print $self->capture_cmd("sudo cloud-init single --name $target") . "\n\n";
    }
    return 1;
}

=head2 wait_for_makefile($domain, %opts)

Waits for the Makefile of the payload to run, and returns true when make exited
zero.  C<$domain> defaults to L</name>.  Takes C<timeout>, default
C<$SETUP_TIMEOUT>.

C<at> starts the Makefile, so there are five waits, in this order:

=over 4

=item * The at queue empties.

=item * The log, F</var/log/$domain.setup.log>, appears.

=item * No process has the log open.

=item * The at queue empties again, because the Makefile can queue more jobs of
its own.

=item * The status file, F</var/log/$domain.setup.status>, appears.
F<setup.sh> writes it as make exits, so this wait is only C<$STATUS_GRACE>.

=back

Returns false when make exited non-zero, and also when the build recorded no
status.  The status comes from a file because C<make | tee> reports the exit
code of tee, and never that of make.

=cut

sub wait_for_makefile {
    my ( $self, $domain, %opts ) = @_;
    my $timeout = $opts{timeout} // $SETUP_TIMEOUT;
    $domain //= $self->name;

    my $log    = "/var/log/$domain.setup.log";
    my $status = "/var/log/$domain.setup.status";
    my $atq    = qq{sudo timeout $timeout bash -c 'until [ \$(atq | wc -l) = 0 ]; do sleep 1; done;'};

    print "Waiting up to $timeout for ATD queue to flush...\n";
    $self->run_cmd($atq);

    print "Waiting up to $timeout for Makefile payload to start...\n";
    $self->run_cmd(qq{sudo timeout $timeout bash -c 'until [ -f $log ]; do sleep 1; done;'});

    print "Waiting up to $timeout for Makefile payload to finish...\n";
    $self->run_cmd(qq{sudo timeout $timeout bash -c 'while lsof | grep $log; do sleep 1; done;'});

    print "Waiting up to $timeout for any makefile queued ATD jobs to flush...\n";
    $self->run_cmd($atq);

    print "Waiting up to $STATUS_GRACE for the build to record its result...\n";
    $self->run_cmd(qq{sudo timeout $STATUS_GRACE bash -c 'until [ -f $status ]; do sleep 1; done;'});
    my $result = $self->capture_cmd("sudo cat $status") // '';
    $result =~ s/\s+//g;

    print "Last log:\n" . ( $self->capture_cmd("sudo tail $log") // '' ) . "\n\nDone!\n";
    return $result eq '0';
}

=head1 THE KEY

A guest is reached with an SSH key.  The private half is the credential for
that machine, so it lives in the secret store and not in the domain directory.
Anything that can read that directory can read a file in it: a process that runs
as the same user, a stolen disk, a backup of F</opt/domains>.

This section has the two halves of that.  The provision that makes a key puts it
in the store, and everything that uses a key gets it back out.

=head2 A domain keeps the key it has

A key lasts as long as the domain does.
L<Provisioner::Recipe::ubuntu/guest_keypair> makes one only for a domain that
has none, and gives the reasons.  C<seal_key> says why it overwrites the key in
the store.

=head2 A key on disk still works

C<key_path> returns the file when there is one.  A domain with a F<key.rsa> on
disk continues to use it.  F<bin/new_config> seals that key the next time it
generates the domain.  Nothing needs a migration, and no run is necessary first.

=head2 They are the domain's, not a guest's

These are class methods that take a domain, not methods on a guest.  Two
callers have no guest.  F<bin/new_config> seals the key before the guest exists
or has an address, and F<bin/guest_key> gets only a domain.  C<new> refuses a
guest with no host, so instance methods need an invented one.

=head2 $ref = Trog::Guest->ref_for_key($domain)

Returns the reference under which the store keeps the key of this domain.

=cut

sub ref_for_key { my ( undef, $domain ) = @_; return "secret:guests/$domain/password" }

=head2 Trog::Guest->seal_key($domain, $path)

Puts the private key at C<$path> into the store, deletes the file, and returns
1.  Returns 0 and changes nothing when the file cannot be read or is empty, or
when the installation has no store.

It overwrites the key in the store, and does not use
L<Trog::Secrets/remember>, which keeps the first answer forever.  A domain
rebuilt from nothing, or a key replaced by hand, has a key the store has not
seen.  The store must hold that one.  A key that did not change seals to the
same bytes.

The file goes only after the store has the key.  If the password prompt or the
store fails, this dies and the key stays on disk.

=cut

sub seal_key {
    my ( $class, $domain, $path ) = @_;

    my $private = eval { File::Slurper::read_binary($path) };
    return 0 unless $private;

    my $store = _store() or return 0;

    # replace, not write.  write builds a new database from only what it gets,
    # and so deletes every other secret in the store.
    Trog::Secrets->replace(
        $store,
        Trog::Credentials->prompt( 'Enter password:', 'keepass' ),
        $class->ref_for_key($domain) => $private,
    );

    unlink $path;
    return 1;
}

=head2 $path = Trog::Guest->key_path($domain, $on_disk)

Returns a path to the private key of this domain that ssh can use, or undef
when there is no key for it anywhere.

C<$on_disk> is the path of a F<key.rsa> in the domain directory.  The caller
knows that path, and this class does not.  To ask L<Trog::HV> loads
L<Sys::Virt> into everything that connects to a guest.  Also, the location of a
domain directory is a question for L<Trog::HV>.  If C<$on_disk> exists, it is
the answer.  See L</A key on disk still works>.

Otherwise the key comes from the store.  It goes into a temporary file that this
process owns, and the file goes away when the process exits.  A second call for
the same domain in one run does not fetch it again.

Returns undef, and does not die, for a domain the store does not know or a store
that cannot be read.  A first build has no key yet, and without a key the
callers use the agent or the ssh configuration.  An installation with no store
gets undef with no password prompt, because a password has nothing to open.

=cut

sub key_path {
    my ( $class, $domain, $on_disk ) = @_;

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- asking whether the old location still holds one
    return $on_disk if defined $on_disk && -f $on_disk;

    state %materialised;
    return $materialised{$domain}{path} if $materialised{$domain};

    my $store = _store() or return undef;

    my %got = eval {
        Trog::Secrets->lookup(
            $store,
            Trog::Credentials->prompt( 'Enter password:', 'keepass' ),
            key => $class->ref_for_key($domain),
        );
    };
    return undef unless $got{key};

    # Keep the object in the hash.  File::Temp deletes the file when the object
    # goes out of scope, and ssh then points at a path that no longer exists.
    my $tmp = File::Temp->new( TEMPLATE => "guest-key-$domain-XXXXXX", TMPDIR => 1 );
    chmod 0600, "$tmp";
    print {$tmp} $got{key} =~ m/\n\z/ ? $got{key} : "$got{key}\n";
    close($tmp) or die "Could not close $tmp: $!\n";

    $materialised{$domain} = { handle => $tmp, path => "$tmp" };
    return $materialised{$domain}{path};
}

=head2 _store

Returns the path of the secret store, or undef when the installation has none.
Callers ask this before any password prompt.  With no store there is no key,
and a prompt with nobody to answer it waits instead of failing.

=cut

sub _store {
    my $store = Trog::Config->path('secrets.kdbx');
    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- whether there is a store at all
    return defined $store && -f $store ? $store : undef;
}

=head1 SEE ALSO

L<Trog::Machine>, L<Trog::HV>, L<Trog::Secrets>

=cut

1;
