package Provisioner::Recipe::hardening;

#ABSTRACT: The kernel settings and the kernel modules that every guest does without.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::hardening - the sysctl values and the blocked kernel
modules of every guest.

=head1 SYNOPSIS

Nobody has to configure this recipe.  Every distro recipe requires it, so every
guest has it.  See L<Provisioner::DistroRecipe/required_recipes>.  To change a
value for a domain, name it:

    somedomain:
        hardening:
            sysctl:
                kernel.kptr_restrict: 1
            blocked_modules:
                - dccp

=head1 DESCRIPTION

L<Provisioner::Recipe::lynis> audits each guest, and its test KRNL-6000
compares the sysctl values of the kernel with a profile.  Its tests NETW-3200
and USB-1000 look for network protocols and for USB storage that the kernel
can load on demand.  This recipe sets what a guest of this fleet can do without.

=head2 sysctl

F</etc/sysctl.d/60-hardening.conf>, which the fragment applies at once and the
kernel reads at each boot:

=over 4

=item * C<dev.tty.ldisc_autoload=0>.  An unprivileged process cannot make the
kernel load a TTY line discipline.  Line disciplines such as C<n_hdlc> had
bugs that let a local user become root.

=item * C<fs.protected_fifos=2>.  A process cannot open a FIFO in a sticky
directory such as F</tmp> that another user owns.

=item * C<fs.suid_dumpable=0>.  A setuid program writes no core dump, which
can hold the secrets that it read as root.

=item * C<kernel.kptr_restrict=2>.  Kernel addresses read as zero, also to
root, so an exploit has to find them another way.

=item * C<net.core.bpf_jit_harden=2>.  The BPF JIT blinds the constants of
every program, so that a program cannot plant code in the JIT output.

=item * C<net.ipv4.conf.all.send_redirects=0> and
C<net.ipv4.conf.default.send_redirects=0>.  A guest sends no ICMP redirects.
The VPN server forwards packets too, but its clients reach each other through
its tunnel, so a redirect never helps them.

=item * C<net.ipv4.conf.default.accept_source_route=0>.  An interface that
comes up later refuses source-routed packets.  The kernel already refuses them
on C<all>.

=back

The profile of Lynis asks for more.  These stay as they are on purpose:

=over 4

=item * C<kernel.modules_disabled>, because at 1 no module loads until the next
boot, and a guest loads modules after boot.

=item * C<net.ipv4.conf.all.rp_filter>, because the strict value 1 drops
packets on an asymmetric route, such as the one of the VPN.  Ubuntu sets 2.

=item * C<kernel.sysrq>, because the console of the hypervisor is how an
operator reaches a guest that does not answer.

=back

=head2 Blocked modules

F</etc/modprobe.d/hardening.conf> gives each module of C<blocked_modules> an
C<install> line that runs F</bin/false>, so that neither a socket of that
protocol nor a device loads it.  A C<blacklist> line alone stops only the load
by alias.  The default list is the protocols DCCP, SCTP, RDS and TIPC, which
no guest uses, and C<usb-storage>, because nobody plugs a disk into a guest.

A module that is already loaded stays loaded until the next boot.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            sysctl => {
                type                 => 'object',
                default              => {},
                description          => 'Each sysctl key and the value that the guest gets.  A key that the recipe does not set by default is added.',
                additionalProperties => { type => 'integer' },
                properties           => {
                    'dev.tty.ldisc_autoload'                    => { type => 'integer', default => 0 },
                    'fs.protected_fifos'                        => { type => 'integer', default => 2 },
                    'fs.suid_dumpable'                          => { type => 'integer', default => 0 },
                    'kernel.kptr_restrict'                      => { type => 'integer', default => 2 },
                    'net.core.bpf_jit_harden'                   => { type => 'integer', default => 2 },
                    'net.ipv4.conf.all.send_redirects'          => { type => 'integer', default => 0 },
                    'net.ipv4.conf.default.send_redirects'      => { type => 'integer', default => 0 },
                    'net.ipv4.conf.default.accept_source_route' => { type => 'integer', default => 0 },
                },
            },
            blocked_modules => {
                type        => 'array',
                default     => [qw{dccp sctp rds tipc usb-storage}],
                uniqueItems => 1,
                items       => { type => 'string', pattern => '^[A-Za-z0-9_-]+$' },
                description => 'The kernel modules that the guest never loads.',
            },
        },
    );
}

sub template_files {
    return (
        'hardening.sysctl.conf.tt'   => 'hardening_sysctl.conf',
        'hardening.modprobe.conf.tt' => 'hardening_modprobe.conf',
    );
}

sub tests {
    return qw{hardening.tt};
}

1;
