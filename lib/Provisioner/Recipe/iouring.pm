package Provisioner::Recipe::iouring;

#ABSTRACT: Gate io_uring to a group, and put the services that need it in it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util qw{any uniq};

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::iouring

=head2 SYNOPSIS

    somedomain:
        iouring:

    # Or open to every process, or closed to all of them:
    somedomain:
        iouring:
            mode: 0
            members:
                - someservice

=head2 DESCRIPTION

Sets C<kernel.io_uring_disabled> and C<kernel.io_uring_group>, makes the group,
and puts the accounts that need io_uring into it.

=head3 What the modes mean, and why the default is 1

From C<Documentation/admin-guide/sysctl/kernel.rst>:

=over 4

=item C<0>

Every process can create io_uring instances. B<This is the kernel's default>.
A stock Ubuntu 24.04 guest already has it, so mode 0 changes nothing, except on
an image hardened to 2.

=item C<1>

Unprivileged processes outside C<kernel.io_uring_group> get C<-EPERM> from
C<io_uring_setup()>. Processes with C<CAP_SYS_ADMIN> are not affected.

=item C<2>

No process can create one, C<CAP_SYS_ADMIN> included.

=back

C<kernel.io_uring_group> has an effect only at 1. At 0 and 2 the kernel ignores
it. Thus the default here is 1, the only mode in which the group and its members
mean anything. io_uring is a large kernel attack surface with a long CVE history.
Mode 1 removes it from every unprivileged process on the guest that is not in
the group.

Set C<mode: 0> to let every process use io_uring. The recipe still makes the
group, ready for mode 1.

=head3 What uses io_uring on these guests: nothing

Measured on a guest:

=over 4

=item * B<mariadb>: the generic Linux bintar that this fleet installs from
C<archive.mariadb.org> has no C<liburing> in its C<NEEDED>. While it runs,
C<mariadbd> holds no io_uring file descriptors. The package from the
distribution links against C<liburing>, but this bintar does not.

=item * B<postgres>: io_uring arrived in PostgreSQL 18. Ubuntu 24.04 ships 16.

=item * B<redis>, B<nginx>: neither uses it.

=back

Thus C<mysql> is in the table below, but it gets nothing from it now. It stays
because being early costs nothing. If somebody replaces the bintar with the
packaged build, a database outside the group gets C<-EPERM> from
C<io_uring_setup()>, and that failure does not name its cause.

So today the recipe gives the other half: at mode 1, no unprivileged process on
the guest can reach io_uring.

=head3 If the machine is itself a hypervisor

Put C<libvirt-qemu> in C<members>. qemu runs unprivileged. On a hypervisor at
mode 1, a qemu outside the group cannot create a ring. Then any guest whose disk
asks for the io_uring AIO backend does not start. C<disk_io> in the
C<provision.conf> of the guest decides whether it asks. This recipe only decides
whether qemu is allowed to.

=head3 Which accounts go in the group

The accounts of the recipes on this guest that run something able to use
io_uring, plus each account in C<members>. A recipe that is not on the guest
adds nothing. So a guest with no database gets an empty group, and no
unprivileged process can reach io_uring.

The recipe adds the members after the makefile and not during it. The accounts
belong to other recipes, which can run after this one. For example, C<mariadb>
creates C<mysql> in its own target.

Then the recipe restarts the service, because a process reads its supplementary
groups only when it starts. C<mariadb> starts during the makefile, in its own
recipe. With C<usermod> alone, it runs outside the group until the next reboot,
and nothing reports it. The restart is C<try-restart>, so a unit that is not
running stays stopped.

This covers only the services in the table below. An account that you add
through C<members> has no unit here. If that service is already running,
restart it yourself.

=head3 A value that does not go down

The fragment writes C<kernel.io_uring_disabled> to F</etc/sysctl.d/> B<and>
applies it with C<sysctl -p>. The two can disagree. A running kernel accepts a
stricter value, but it can refuse a less strict one, depending on the kernel. So
the fragment reads the value back after it applies it, and warns if the running
kernel kept its own value. The file is still correct, and the next boot uses it.

=head3 deps

None. The sysctl belongs to the kernel, and C<groupadd> makes the group.

=head3 args

=over 4

=item mode

0, 1 or 2, as above. Defaults to 1.

=item group

The name of the group. Defaults to C<io_uring>.

=item members

More accounts to put in the group, in addition to the ones that come from the
recipes on the guest. The name is not C<users>, because C<users> is already a
global template variable. A recipe arg with that name gets the account list of
the guest, and not the value you gave it.

=back

=head3 enrich

Adds to C<members> the accounts of the recipes on this guest that run something
able to use io_uring, and sets C<restart_units> to their services.  See
L</Which accounts go in the group>.

=cut

# The recipes that run something able to use io_uring, with their accounts.
#
# A table here, and not a required_recipes on each of those recipes, so that a
# database does not bring this recipe and its stricter mode onto a guest that did
# not ask for it.  The POD says why mysql is here although nothing uses io_uring.
#
# The units are the services to restart after their accounts join the group,
# because a process reads its groups only when it starts.
my %SERVICES = (
    mariadb => { users => ['mysql'], units => ['mariadb'] },
);

sub args {
    return (
        type       => 'object',
        properties => {
            mode  => { type => 'integer', enum    => [ 0, 1, 2 ],           default => 1 },
            group => { type => 'string',  pattern => '^[a-z_][a-z0-9_-]*$', default => 'io_uring' },

            # Not `users`, which is a global template variable.  See members in the POD.
            members => { type => 'array', items => { type => 'string' }, default => [] },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    my @modules = @{ $opts{modules} // [] };
    my @members = @{ $opts{members} // [] };
    my @units;

    foreach my $recipe ( sort keys %SERVICES ) {
        next unless any { $_ eq $recipe } @modules;
        push @members, @{ $SERVICES{$recipe}{users} };
        push @units,   @{ $SERVICES{$recipe}{units} };
    }

    $opts{members} = [ sort( uniq(@members) ) ];

    # Only the units in %SERVICES.  The POD says what to do for an account in `members`.
    $opts{restart_units} = [ sort( uniq(@units) ) ];

    return %opts;
}

sub template_files {
    return (
        'iouring.sysctl.conf.tt' => 'io_uring.conf',
    );
}

sub tests {
    return qw{iouring.tt};
}

1;
