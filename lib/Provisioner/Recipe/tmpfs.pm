package Provisioner::Recipe::tmpfs;

#ABSTRACT: Put /tmp on a tmpfs, at a size you choose.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::tmpfs

=head2 SYNOPSIS

    somedomain:
        tmpfs:

    # Or with a size of your own:
    somedomain:
        tmpfs:
            size: 2G

=head2 DESCRIPTION

Installs a C<tmp.mount> unit so C</tmp> is a tmpfs rather than a directory on
the root filesystem.

Debian and Ubuntu ship the unit in F</usr/share/systemd/> rather than
F</usr/lib/systemd/system/>, which is their way of shipping it turned off:
nothing can enable a unit systemd cannot see. So this writes its own into
F</etc/systemd/system/tmp.mount>, which is also what makes the size
configurable -- there is nowhere to put a drop-in for a unit that does not
exist.

=head3 It mounts during the build, on purpose

The first cut of this enabled the unit and deliberately did not start it, on the
theory that mounting over C</tmp> mid-provision was asking for trouble. That
theory did not survive a guest: C<tmp.mount> is C<WantedBy=local-fs.target>, and
the next C<systemctl restart> of anything with default dependencies re-pulls
that target and mounts it. C<nostubresolver> restarting C<systemd-resolved> was
what did it, from the middle of the postrun queue -- so "enabled but not
started" is not a state a running system stays in.

Since it is going to mount either way, it mounts here: synchronously, from this
recipe's own makefile target, where every recipe after it sees the same C</tmp>
and a mount that fails fails the build rather than surfacing later.

What made the mid-provision mount dangerous was that the build ran out of
C</tmp>. It does not any more -- F<setup.tmpl> unpacks the payload into
F</var/tmp> -- so there is nothing under C</tmp> for this to cover over except
whatever cloud-init and apt left behind, which is what C<systemd> means when it
says B<Directory /tmp to mount over is not empty, mounting anyway>.

Whatever that was stays on the root filesystem underneath the mount, unreachable
and never added to again -- about 76K of socket directories and systemd's
per-service private ones on the guest this was tested against. Every boot after
this one mounts the tmpfs before anything writes to C</tmp>, so it does not
accumulate. It is not worth an C<rm -rf /tmp/*> in a provisioning recipe to
reclaim.

=head3 deps

None. C<tmp.mount> is systemd's, and tmpfs is the kernel's.

=head3 args

=over 4

=item size

How large the tmpfs may grow, in the syntax C<mount> takes for tmpfs: a
percentage of RAM (C<50%>), or a size with a suffix (C<2G>, C<512M>), or plain
bytes. Defaults to C<50%>, which is what systemd's own C<tmp.mount> ships.

It is a ceiling rather than a reservation -- a tmpfs occupies what is written to
it and no more -- so the cost of a generous number is that something filling
C</tmp> can take that much memory, not that the guest starts with less.

A percentage reaches the unit file doubled, as C<50%%>: C<Options=> is a setting
systemd expands specifiers in, and a lone C<%> there is the start of one.

=back

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            size => {

                # What tmpfs itself accepts: a percentage of RAM, a number with
                # a k/m/g suffix, or plain bytes.  Checked here because the
                # failure is otherwise a mount that refuses at boot, on a guest
                # nobody is watching, with /tmp quietly staying on the disk.
                type    => 'string',
                pattern => '^[1-9][0-9]*(?:%|[kKmMgG])?$',
                default => '50%',
            },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # systemd expands specifiers in Options=, where % begins one.  A literal
    # percent is written %%, so `50%` has to reach the unit as `50%%` -- and a
    # size given as 2G must not be mangled on the way.
    ( $opts{unit_size} = $opts{size} ) =~ s/%/%%/;

    return %opts;
}

sub template_files {
    return (
        'tmpfs.mount.tt' => 'tmp.mount',
    );
}

sub tests {
    return qw{tmpfs.tt};
}

1;
