package Provisioner::Recipe::iouring;

#ABSTRACT: Gate io_uring to a group, and put the services that need it in it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use List::Util qw{any uniq};

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::iouring

=head2 SYNOPSIS

    somedomain:
        iouring:

    # Or open to everything, or shut entirely:
    somedomain:
        iouring:
            mode: 0
            members:
                - someservice

=head2 DESCRIPTION

Sets C<kernel.io_uring_disabled> and C<kernel.io_uring_group>, makes the group,
and puts the accounts that actually need io_uring into it.

=head3 What the modes mean, and why the default is 1

From C<Documentation/admin-guide/sysctl/kernel.rst>:

=over 4

=item C<0>

Every process may create io_uring instances. B<This is the kernel's default>,
and what a stock Ubuntu 24.04 guest already has -- so a recipe that sets 0 is a
recipe that does nothing, except on an image hardened to 2.

=item C<1>

Unprivileged processes outside C<kernel.io_uring_group> get C<-EPERM> from
C<io_uring_setup()>. Processes with C<CAP_SYS_ADMIN> are unaffected.

=item C<2>

Nobody may create one, C<CAP_SYS_ADMIN> included.

=back

C<kernel.io_uring_group> only bites at 1. At 0 and 2 it is inert, which is why
the default here is 1: it is the only setting under which making a group and
managing its membership means anything, and it is the one that buys something --
io_uring is a large kernel attack surface with a long CVE history, and this takes
it away from every unprivileged process on the guest that is not a service which
asked for it.

Set C<mode: 0> to have the issue's literal reading: on for everything, group
made and standing by.

=head3 What actually uses io_uring on these guests today: nothing

The issue this came from asked to go and look. The answer, measured on a guest:

=over 4

=item * B<mariadb> -- the generic Linux bintar this fleet installs from
C<archive.mariadb.org> has no C<liburing> in its C<NEEDED>, and C<mariadbd> holds
no io_uring file descriptors while running. The distribution's package is built
against it; this one is not.

=item * B<postgres> -- io_uring arrived in PostgreSQL 18. Ubuntu 24.04 ships 16.

=item * B<redis>, B<nginx> -- neither uses it.

=back

So C<mysql> is in the table below and gains nothing from it at present. It stays
because the cost of being early is nothing at all, and the cost of being late is
a database that gets C<-EPERM> from C<io_uring_setup()> the day somebody swaps
the bintar for the packaged build -- which is not a failure that names itself.

What this recipe buys today is therefore the other half: io_uring is a large
kernel attack surface, and at mode 1 no unprivileged process on the guest can
reach it.

=head3 If the machine is itself a hypervisor

Put C<libvirt-qemu> in C<members>. The domain XML this repo generates asks qemu
for C<io='io_uring'> on every guest disk, and qemu runs unprivileged -- so at
mode 1, on a host outside the group, every guest fails to start. The two halves
of this were written together and will bite together.

=head3 Which accounts go in the group

The ones belonging to recipes on this guest that run something able to use
io_uring, plus anything named in C<members>. Nothing is added for a recipe that is
not present, so a guest with no database gets a group with nobody in it and an
io_uring nothing can reach -- which is the point.

Membership is applied after the makefile rather than during it, because the
accounts belong to other recipes and this one sorts ahead of most of them:
C<mariadb> creates C<mysql> in its own target, which has not run yet.

=head3 A value that will not go down

C<kernel.io_uring_disabled> is written to F</etc/sysctl.d/> B<and> applied with
C<sysctl -p>, and the two can disagree. Tightening at runtime works; loosening
may not, depending on the kernel. So the fragment reads the value back after
applying it and says so when the running kernel kept its own -- the file is
still correct, and the next boot honours it.

=head3 deps

None. The sysctl is the kernel's and the group is C<groupadd>'s.

=head3 args

=over 4

=item mode

0, 1 or 2 as above. Defaults to 1.

=item group

What to call the group. Defaults to C<io_uring>.

=item members

Extra accounts to put in the group, on top of the ones worked out from the
recipes present. Not called C<users>, which is a global template variable
already: a recipe arg by that name is handed the guest's account list rather
than anything it asked for.

=back

=cut

# Which recipes run something that can use io_uring, and the account it runs as.
#
# Kept here rather than as a required_recipes on each of them, so that asking for
# a database does not drag this recipe -- and its posture change -- onto a guest
# that never asked for it.  A recipe absent from this guest contributes nothing.
# Nothing here actually uses io_uring on a stock guest yet -- see the POD, which
# says what was measured and why mysql is listed anyway.
my %SERVICE_USERS = (
    mariadb => ['mysql'],
);

sub args {
    return (
        type       => 'object',
        properties => {
            mode  => { type => 'integer', enum    => [ 0, 1, 2 ],           default => 1 },
            group => { type => 'string',  pattern => '^[a-z_][a-z0-9_-]*$', default => 'io_uring' },

            # Not `users`: that is already a global template variable holding
            # the guest's accounts, as a list of hashes, and a recipe arg of the
            # same name is handed those instead of anything it asked for.
            members => { type => 'array', items => { type => 'string' }, default => [] },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    my @modules = @{ $opts{modules} // [] };
    my @members = @{ $opts{members} // [] };

    foreach my $recipe ( sort keys %SERVICE_USERS ) {
        next unless any { $_ eq $recipe } @modules;
        push @members, @{ $SERVICE_USERS{$recipe} };
    }

    $opts{members} = [ sort( uniq(@members) ) ];

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
