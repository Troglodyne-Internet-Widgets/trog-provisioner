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

Trog::Guest - a VM we have just built, and are now waiting on

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

The other end of the job from L<Trog::HV>: the machine we just asked a
hypervisor to make.  Everything about reaching it -- the connection, running
commands, getting files onto it -- is L<Trog::Machine>'s, and the same
reasoning applies about not using sftp.  What is here is the waiting.

A guest spends its first few minutes not being ready, in several distinct ways,
and each of them needs a different question asked.  Those questions used to
live as free subs in F<bin/provision> taking a bare L<Net::OpenSSH::More>
handle, which meant F<bin/restore> had its own copy of the connecting half and
neither could be tested without a VM.

=head1 CLASS METHODS

=head2 new(%opts)

C<host> and C<user> are required, C<key_path> nearly always wanted, and C<name>
is what to call this guest in messages.

=cut

# How long to wait for things a guest does exactly once, on first boot.
our $BOOT_TIMEOUT = 300;

# Seconds between connection attempts, which is Net::OpenSSH::More's own
# default.  Named here because wait_for_ssh divides the boot timeout by it.
our $SSH_RETRY_INTERVAL = 6;

# The whole Makefile runs inside this one, not just the waiting: the first wait
# is on the at queue, and the job sits there for as long as the build takes.
# The longest of them is a domain that builds perl from source and installs
# ninety-odd distributions after it, which takes about twenty minutes.
#
# Trog::Machine::_unhang has to allow at least this long, or it decides a guest
# that is still building has hung.
our $SETUP_TIMEOUT = $ENV{TROG_SETUP_TIMEOUT} || '90m';

# The build writes this as make exits, so it is there by the time the log is
# closed; waiting the setup timeout for one that is missing just hangs.
our $STATUS_GRACE = '60s';

sub new {
    my ( $class, %opts ) = @_;

    die "A guest needs a host to connect to\n" unless defined $opts{host} && length $opts{host};
    return $class->SUPER::new(%opts);
}

=head1 IDENTITY

=head2 name

What this guest is called, for messages.  Falls back to its address.

=head2 describe

C<user@host>, or the name and address together when we have both.

=cut

sub name ($self) { return $self->{name} // $self->ssh_host }

sub describe {
    my ($self) = @_;
    my $target = $self->ssh_target;
    return defined $self->{name} ? "$self->{name} ($target)" : $target;
}

=head1 WAITING

=head2 wait_for_ssh(%opts)

Wait until we can actually SSH in, and return the guest.  C<timeout> seconds,
default 300.

Two separate things have to be true, and checking only the first is how you get
a confusing failure three steps later: the port has to be open, I<and> the
connection has to succeed.  A VM that is listening but not yet accepting our key
is not one we can do anything with.

=cut

sub wait_for_ssh {
    my ( $self, %opts ) = @_;
    my $timeout = $opts{timeout} // $BOOT_TIMEOUT;

    print 'Waiting for ' . $self->ssh_host . ":22 to come live...\n";
    Net::EmptyPort::wait_port( { host => $self->ssh_host, port => 22, max_wait => $timeout } )
      or die 'SSH port on ' . $self->describe . " never came up after ${timeout}s\n";

    # Opening it is the actual test; the port being up only means something is
    # listening.  Given the same window as the port rather than the library's
    # own minute: sshd answers long before cloud-init has finished writing
    # authorized_keys, and ssh-import-id fetches some of those keys from GitHub,
    # so a minute ran out on guests that were coming up perfectly well.
    $self->ssh( retry_interval => $SSH_RETRY_INTERVAL, retry_max => int( $timeout / $SSH_RETRY_INTERVAL ) || 1 )
      or die 'Could not establish an SSH connection to ' . $self->describe . "\n";
    return $self;
}

=head2 wait_for_cloud_init($domain, %opts)

Wait for cloud-init to finish, then check whether it is telling the truth.

C<cloud-init status --wait> can report success for a run in which individual
modules failed, so afterwards we read the analysis and re-run whatever came
back C<FAIL>.  Re-running means removing the semaphore first, since cloud-init
will otherwise decline on the grounds that it has already done it.

=cut

sub wait_for_cloud_init {
    my ( $self, $domain, %opts ) = @_;
    my $timeout = $opts{timeout} // $SETUP_TIMEOUT;
    $domain //= $self->name;

    print "Waiting up to $timeout for Cloud-init to finish...\n";
    my $rc = $self->run_cmd(qq{sudo timeout $timeout bash -c 'until grep "Boot configuration complete." /var/log/cloud-init-output.log; do sleep 1; done;'});
    print "Done!\n";
    die 'Cloud init reported failure on ' . $self->describe . ", investigate the machine\n" if $rc;

    # See if we got a lying exit code above.
    my $raw    = $self->capture_cmd('sudo cloud-init analyze dump');
    my $parsed = eval { JSON::MaybeXS->new( utf8 => 1 )->decode($raw) };
    die "cloud-init analyze dump on " . $self->describe . " did not return a JSON array\n"
      unless ref $parsed eq 'ARRAY';

    foreach my $fail ( grep { ( $_->{result} // '' ) eq 'FAIL' } @$parsed ) {
        my ( $module, $mtarget ) = split( m{/}, $fail->{name} );
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

Wait for the payload's Makefile to run, and return whether it succeeded.

It is started by C<at>, so this is five waits and not one: the queue has to
drain, the log has to appear, the log has to stop being written to, the queue
has to drain again -- because the Makefile is entirely at liberty to queue more
work of its own -- and then the status file has to appear, which F<setup.sh>
writes as make exits -- briefly, since a file that is missing by then is not
coming.

False unless make exited zero, a build that recorded nothing included.  The
status is read from a file because C<make | tee> reports tee's exit code and
never make's.

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

The private half of the key a guest is reached with used to sit in the domain
directory as F<key.rsa>, mode 0600.  It is the credential for the machine it
belongs to, so anything that could read that directory -- a process running as
the same user, a stolen disk, a backup of F</opt/domains> -- had the way in to
every guest.

It lives in the secret store now.  What is here is the two halves of that: the
provision that makes a key puts it there, and everything that needs to use one
gets it back out.

=head2 A domain keeps the key it has

A key lasts as long as the domain does.
L<Provisioner::Recipe::ubuntu/guest_keypair> mints one only for a domain with
none, and has the reasoning.

C<seal_key> overwrites rather than going through L<Trog::Secrets/remember>,
which keeps the first answer forever.  A key that has not changed re-seals to the
same bytes; one that has -- a domain rebuilt from nothing, a key replaced by hand
-- has to land in the store rather than be ignored in favor of the old one.

=head2 A guest built before this still works

C<key_path> hands back the file when there is one.  An installation whose domains
have a F<key.rsa> on disk goes on using it, and each domain seals itself the next
time it is provisioned -- there is nothing to migrate and no run to make first.

=head2 They are the domain's, not a guest's

Class methods taking a domain, rather than methods on a guest, because two of
the callers have no guest to call one on: C<bin/new_config> seals at generate
time, before the guest exists or has an address, and C<bin/guest_key> is handed
a domain and nothing else.  C<new> refuses a guest with no host, so making these
instance methods would mean inventing one.

=head2 $ref = Trog::Guest->ref_for_key($domain)

The reference the store keeps this domain's key under.

=cut

sub ref_for_key { my ( undef, $domain ) = @_; return "secret:guests/$domain/password" }

=head2 Trog::Guest->seal_key($domain, $path)

Put the private half at C<$path> into the store and take it off the disk.

Overwrites what was there rather than keeping the first answer: a domain rebuilt
from nothing, or a key replaced by hand, has one the store has not seen, and that
is the one to hold.  A key that has not changed re-seals to the same bytes.

The file goes only once the store has it, so a failure anywhere in here leaves
the key where it was rather than nowhere.

=cut

sub seal_key {
    my ( $class, $domain, $path ) = @_;

    my $private = eval { File::Slurper::read_binary($path) };
    return 0 unless defined $private && length $private;

    my $store = _store() or return 0;

    # replace, not write.  write builds a new database out of what it is handed,
    # which against the real store would leave it holding this key and nothing
    # else -- every registrar credential and mail password in it gone.
    Trog::Secrets->replace(
        $store,
        Trog::Credentials->prompt( 'Enter password:', 'keepass' ),
        $class->ref_for_key($domain) => $private,
    );

    unlink $path;
    return 1;
}

=head2 $path = Trog::Guest->key_path($domain, $on_disk)

A path to this domain's private key that ssh can be pointed at, or undef when
there is no key for it anywhere.

C<$on_disk> is where the key used to be kept, which the caller knows and this
does not: asking L<Trog::HV> would drag L<Sys::Virt> into everything that wants
to reach a guest, and where a domain directory is is L<Trog::HV>'s question
rather than this one.  Given one that exists, that is the answer -- see
L</A guest built before this still works>.

Otherwise the store's copy, written to a temporary file that belongs to this
process and goes away with it.  Asked for twice in one run it is fetched once.

Undef rather than a die for a domain the store has never heard of: a first build
has no key yet, and the callers already treat "no key" as "use the agent or the
ssh config", which is a better answer than a path to nothing.  An installation
with no store at all is answered without asking for a password, since there is
nothing a password would open.

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

    # Kept in the hash as well as on disk: File::Temp removes the file when the
    # object goes out of scope, so letting go of it would leave ssh pointed at a
    # path that had just been unlinked.
    my $tmp = File::Temp->new( TEMPLATE => "guest-key-$domain-XXXXXX", TMPDIR => 1 );
    chmod 0600, "$tmp";
    print {$tmp} $got{key} =~ m/\n\z/ ? $got{key} : "$got{key}\n";
    close($tmp) or die "Could not close $tmp: $!\n";

    $materialised{$domain} = { handle => $tmp, path => "$tmp" };
    return $materialised{$domain}{path};
}

# The store, or nothing, asked before any password is.  An installation with no
# store cannot be holding a key, and asking for one would mean a prompt with
# nothing behind it -- which in a run with nobody to type at is a wait rather
# than a refusal.  bin/new_config reaches this on every generate, so that wait
# was the whole suite.
sub _store {
    my $store = Trog::Config->path('secrets.kdbx');
    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- whether there is a store at all
    return defined $store && -f $store ? $store : undef;
}

=head1 SEE ALSO

L<Trog::Machine>, L<Trog::HV>, L<Trog::Secrets>

=cut

1;
