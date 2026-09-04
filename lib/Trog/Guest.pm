package Trog::Guest;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';
use parent 'Trog::Machine';

use Net::EmptyPort();
use JSON::MaybeXS();

=head1 NAME

Trog::Guest - a VM we have just built, and are now waiting on

=head1 SYNOPSIS

    use Trog::Guest();

    my $domain = 'vm.example.com';

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
our $SETUP_TIMEOUT = '30m';

sub new {
    my ($class, %opts) = @_;

    die "A guest needs a host to connect to\n" unless defined $opts{host} && length $opts{host};
    return $class->SUPER::new(%opts);
}

=head1 IDENTITY

=head2 name

What this guest is called, for messages.  Falls back to its address.

=head2 describe

C<user@host>, or the name and address together when we have both.

=cut

sub name { return $_[0]->{name} // $_[0]->ssh_host }

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
    my ($self, %opts) = @_;
    my $timeout = $opts{timeout} // $BOOT_TIMEOUT;

    print 'Waiting for ' . $self->ssh_host . ":22 to come live...\n";
    Net::EmptyPort::wait_port({ host => $self->ssh_host, port => 22, max_wait => $timeout })
      or die 'SSH port on ' . $self->describe . " never came up after ${timeout}s\n";

    # Opening it is the actual test; the port being up only means something is
    # listening.
    $self->ssh or die 'Could not establish an SSH connection to ' . $self->describe . "\n";
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
    my ($self, $domain, %opts) = @_;
    my $timeout = $opts{timeout} // $SETUP_TIMEOUT;
    $domain //= $self->name;

    print "Waiting up to $timeout for Cloud-init to finish...\n";
    my $rc = $self->run(
        qq{sudo timeout $timeout bash -c 'until grep "Boot configuration complete." /var/log/cloud-init-output.log; do sleep 1; done;'});
    print "Done!\n";
    die 'Cloud init reported failure on ' . $self->describe . ", investigate the machine\n" if $rc;

    # See if we got a lying exit code above.
    my $raw = $self->capture('sudo cloud-init analyze dump');
    my $parsed = eval { JSON::MaybeXS->new(utf8 => 1)->decode($raw) };
    die "cloud-init analyze dump on " . $self->describe . " did not return a JSON array\n"
      unless ref $parsed eq 'ARRAY';

    foreach my $fail (grep { ($_->{result} // '') eq 'FAIL' } @$parsed) {
        my ($module, $mtarget) = split('/', $fail->{name});
        next unless $mtarget;
        my ($stage, $target) = split('-', $mtarget);
        next unless $target;

        print "$target failed during $stage, re-running...\n";
        $self->run_sudo(qw{rm}, "/var/lib/cloud/instances/$domain/sem/$stage\_$target");
        print $self->capture("sudo cloud-init single --name $target") . "\n\n";
    }
    return 1;
}

=head2 wait_for_makefile($domain, %opts)

Wait for the payload's Makefile to run to completion.

It is started by C<at>, so this is four waits and not one: the queue has to
drain, the log has to appear, the log has to stop being written to, and then
the queue has to drain again -- because the Makefile is entirely at liberty to
queue more work of its own.

=cut

sub wait_for_makefile {
    my ($self, $domain, %opts) = @_;
    my $timeout = $opts{timeout} // $SETUP_TIMEOUT;
    $domain //= $self->name;

    my $log = "/var/log/$domain.setup.log";
    my $atq = qq{sudo timeout $timeout bash -c 'until [ \$(atq | wc -l) = 0 ]; do sleep 1; done;'};

    print "Waiting up to $timeout for ATD queue to flush...\n";
    $self->run($atq);

    print "Waiting up to $timeout for Makefile payload to start...\n";
    $self->run(qq{sudo timeout $timeout bash -c 'until [ -f $log ]; do sleep 1; done;'});

    print "Waiting up to $timeout for Makefile payload to finish...\n";
    $self->run(qq{sudo timeout $timeout bash -c 'while lsof | grep $log; do sleep 1; done;'});

    print "Waiting up to $timeout for any makefile queued ATD jobs to flush...\n";
    $self->run($atq);

    print "Last log:\n" . ($self->capture("sudo tail $log") // '') . "\n";
    print "\nDone!\n";
    return 1;
}

=head1 SEE ALSO

L<Trog::Machine>, L<Trog::HV>

=cut

1;
