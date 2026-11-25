package Provisioner::Recipe::zswap;

#ABSTRACT: Compress swap in memory, give it a swap file, and let systemd-oomd kill a runaway first.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util qw{uniq};
use Provisioner::Cookbook();

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::zswap

=head2 SYNOPSIS

    somedomain:
        zswap:

    # Or with settings of your own:
    somedomain:
        zswap:
            swap_size: 4G
            compressor: lz4
            max_pool_percent: 25
            kill_on_pressure: []
            protect:
                - dbus.service
                - someservice.service
            oomd_omit:
                - otherservice.service

=head2 DESCRIPTION

A guest with no swap has one answer to a process that takes all of its memory:
the kernel OOM killer.  The kernel picks its victim by size alone, and it can
pick C<dbus-daemon>.  When dbus goes, systemd, logind and ssh logins stop
working, and the guest needs a power cycle.  This recipe puts three things in
front of that.

=over 4

=item zswap

zswap is a compressed cache in memory for pages on their way to swap.  A page
that goes to swap is compressed and kept in RAM, and goes to the disk only when
the pool is full.  See L<https://docs.kernel.org/admin-guide/mm/zswap.html>.

=item A swap file

zswap needs a swap device behind it.  The recipe makes F</swapfile> and the
unit F</etc/systemd/system/swapfile.swap> that turns it on at each boot.

=item systemd-oomd

systemd-oomd watches memory pressure and swap use for each cgroup.  It kills a
whole service or session before the kernel has to pick one process.  The recipe
installs it and gives it something to watch, see L</What systemd-oomd watches>.

=back

=head3 zswap is set at run time, not on the kernel command line

The kernel of Ubuntu has zswap built in and turned off
(C<CONFIG_ZSWAP_DEFAULT_ON> is not set).  The recipe writes its settings to
F</sys/module/zswap/parameters/> through F</etc/tmpfiles.d/zswap.conf>.
C<systemd-tmpfiles> applies that file at each boot, and the fragment applies it
once during the build.  So zswap is on before the build ends, with no reboot.

The other way is C<zswap.enabled=1> on the kernel command line.  The recipe
does not do that, because the command line belongs to
L<Provisioner::Recipe::grubconf>, and two recipes cannot both own
C<GRUB_CMDLINE_LINUX>.

A tmpfiles C<w> line writes only to a file that exists.  So on a kernel with
no C<zpool> parameter, that line does nothing and the others still apply.

=head3 The swap file

C<swap_size> is resolved on the guest by F<scripts/make_swapfile>, because only
the guest knows its memory.  The script makes the file with C<fallocate>, which
works on ext4 and xfs, but not on btrfs.  The root filesystem of the cloud
image is ext4.

The script leaves alone a file that has the right size and a swap signature.
It replaces a file of another size, after it turns that file off.  So a new
C<swap_size> takes effect on the next build.  If the disk does not have the
room, C<fallocate> fails and so does the build.

The recipe does not touch other swap.  A guest at Linode has a small swap disk
of its own, and keeps it beside the file.

=head3 What systemd-oomd watches

The package starts systemd-oomd when it installs, before the swap file exists.
That oomd logs C<No swap; memory pressure usage will be degraded>, and on one
guest it never took its name on D-Bus, so C<oomctl> timed out.  So the
fragment restarts it after the swap file is on.

systemd-oomd acts only on the cgroups that a unit marks for it.  With nothing
marked, it runs and does nothing.  The recipe marks these:

=over 4

=item C<-.slice>, the root slice, with C<ManagedOOMSwap=kill>

When more than 90% of memory and more than 90% of swap are in use,
systemd-oomd kills the cgroup that uses the most swap.  90% is the
C<SwapUsedLimit> of systemd-oomd.  This is the one that catches a leak: the
leak fills swap, and the leak is the largest user.

=item Each slice in C<kill_on_pressure>, with C<ManagedOOMMemoryPressure=kill>

When the memory pressure of a cgroup under the slice stays over 60% for 20
seconds, systemd-oomd kills it.  Those are the defaults of systemd-oomd 255,
which Ubuntu 24.04 ships.  Pressure is the share of time that tasks wait for
memory.  A guest that thrashes has high pressure before swap is full.  The
default is C<system.slice> and C<user.slice>: every service, and every login
session.  The package of Ubuntu also marks C<user@.service> itself, at 50%.

=back

Measured on a guest with 7.6G of RAM and the defaults: a service that
allocated 64M of random data every 50ms was killed by systemd-oomd after 35
seconds, under the rule for swap.  The kernel OOM killer did not run, and
C<dbus-daemon> kept its PID.

=head3 What is protected

Each unit in C<protect> gets a drop-in with C<OOMScoreAdjust=-900> and
C<ManagedOOMPreference=omit>.  The first makes the kernel OOM killer pick
almost anything else first.  The second makes systemd-oomd skip the unit.
-900 and not -1000, because at -1000 the kernel cannot kill the unit even when
the unit is the leak.

A recipe names its own units in L<Provisioner::Recipe/oom_protect>, for
example C<mariadb.service>.  The recipe adds the units of each recipe on the
guest to C<protect>.  An operator does not have to list them.

Each unit in C<oomd_omit> gets a drop-in with C<ManagedOOMPreference=omit>
alone.  A recipe names such units in L<Provisioner::Recipe/oomd_omit>.  This is
for a unit whose children must keep the score of the kernel, such as
C<ssh.service>.  Measured on a guest: sshd sets its listener to -1000 by itself,
and gives each session the score that systemd gave the listener.  With
C<ssh.service> in C<protect>, every login shell ran at -900.  So do not put
C<ssh.service> in C<protect>.  A unit in both lists is protected.

A running process reads C<OOMScoreAdjust> only when it starts.  The recipe does
not restart a unit to apply it, because to restart dbus on a running guest
breaks logind and every session.  After the makefile,
F<scripts/oom_protect_running> sets the score of each running main process with
C<choom> instead.  It runs after the makefile, because a unit such as
C<mariadb.service> starts in the target of its own recipe, which can run after
this one.

systemd applies C<ManagedOOMPreference> when the unit starts.  Whether it also
applies to a unit that already runs was not measured.

=head3 deps

C<systemd-oomd>, in L<Provisioner::Recipe::Ubuntu::zswap>.  zswap and swap
belong to the kernel.

=head3 args

=over 4

=item swap_size

The size of F</swapfile>.  That is a percentage of RAM (C<50%>), a size with a
suffix of C<K>, C<M> or C<G> (C<2G>), or a number of bytes.  The default is
C<50%>.

=item compressor

The algorithm that zswap compresses with.  The default is C<zstd>.  C<lz4> is faster and
compresses less.

=item zpool

The allocator that holds the compressed pages.  The default is C<zsmalloc>,
which packs the most into memory.  The kernel of Ubuntu 24.04 defaults to
C<zbud>, which stores at most two compressed pages in one page.  A kernel with
no C<zpool> parameter ignores this.

=item max_pool_percent

The largest share of RAM that the compressed pool can take, as a percentage.
When the pool is full, zswap writes the oldest pages to the swap file.  The
default is 20, the default of the kernel.

=item kill_on_pressure

The slices that systemd-oomd watches for memory pressure, see
L</What systemd-oomd watches>.  An empty list turns that off, and leaves only
the watch on swap.

=item protect

The units that systemd-oomd skips and the kernel OOM killer avoids, see
L</What is protected>.  The default is C<dbus.service>.  The recipe adds the
units that the recipes on the guest name, whatever this list says.

=item oomd_omit

The units that systemd-oomd skips, with no change to their kernel OOM score,
see L</What is protected>.  Empty by default.  The recipe adds the units that
the recipes on the guest name.

=back

Returns the schema of these settings, as a list of key and value pairs.

    my %schema = $recipe->args();

=cut

# A size as make_swapfile takes it: bytes, a percent of memory, or K, M or G.
# make_swapfile reads the suffix with numfmt --from=iec, which takes the
# suffixes in upper case only.
my $SWAP_SIZE = qr/\A [1-9] [[:digit:]]* (?: % | [KMG] )? \z/;

# A systemd unit name, with its type.  It becomes a path under
# /etc/systemd/system, so nothing that can climb out of it.
my $UNIT_NAME = qr/\A [[:alnum:]_\@:.-]+ [.] (?: service | slice | scope ) \z/;

sub args {
    return (
        type       => 'object',
        properties => {
            swap_size => {
                type        => 'string',
                pattern     => "$SWAP_SIZE",
                default     => '50%',
                description => 'The size of /swapfile: a percentage of RAM, a size with K, M or G, or bytes.',
            },
            compressor => {
                type        => 'string',
                enum        => [qw{zstd lz4 lzo lzo-rle deflate 842}],
                default     => 'zstd',
                description => 'The algorithm that zswap compresses with.',
            },
            zpool => {
                type        => 'string',
                enum        => [qw{zsmalloc zbud z3fold}],
                default     => 'zsmalloc',
                description => 'The allocator of the compressed pool.  A kernel with no zpool parameter ignores it.',
            },
            max_pool_percent => {
                type        => 'integer',
                minimum     => 1,
                maximum     => 100,
                default     => 20,
                description => 'The largest share of RAM, in percent, that the compressed pool takes.',
            },
            kill_on_pressure => {
                type        => 'array',
                items       => { type => 'string', pattern => "$UNIT_NAME" },
                default     => [qw{system.slice user.slice}],
                description => 'The slices whose children systemd-oomd kills under memory pressure.',
            },
            protect => {
                type        => 'array',
                items       => { type => 'string', pattern => "$UNIT_NAME" },
                default     => [qw{dbus.service}],
                description => 'The units that systemd-oomd skips and the kernel OOM killer avoids.',
            },
            oomd_omit => {
                type        => 'array',
                items       => { type => 'string', pattern => "$UNIT_NAME" },
                default     => [],
                description => 'The units that systemd-oomd skips, with their kernel OOM score left alone.',
            },
        },
    );
}

=head2 $recipe->enrich(%opts)

Adds to C<protect> the units that each recipe in C<modules> names in
L<Provisioner::Recipe/oom_protect>, and to C<oomd_omit> the units that each
names in L<Provisioner::Recipe/oomd_omit>.  Takes out of C<oomd_omit> each unit
that is in C<protect>, because two drop-ins for one unit would disagree.

Returns C<%opts> with the new C<protect> and C<oomd_omit>.

    my %enriched = $recipe->enrich( modules => [qw{mariadb sshd}], protect => ['dbus.service'], oomd_omit => [] );

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @recipes = map { local ($_) = $_; Provisioner::Cookbook->load($_) } @{ $opts{modules} // [] };
    $opts{protect} = [ sort( uniq( @{ $opts{protect} }, map { local ($_) = $_; $_->oom_protect() } @recipes ) ) ];

    my %protected = map { $_ => 1 } @{ $opts{protect} };
    $opts{oomd_omit} = [ sort grep { !$protected{$_} } uniq( @{ $opts{oomd_omit} }, map { local ($_) = $_; $_->oomd_omit() } @recipes ) ];

    return %opts;
}

=head2 $recipe->machine_wide(%opts)

Every setting.  The recipe has only a global half, and each setting is a fact
about the machine.  A list comes back as one string, its members sorted and
joined with commas.

Returns a map from the name of each setting to its value, as a list of pairs.

    my %settings = $recipe->machine_wide( swap_size => '2G' );

=cut

sub machine_wide {
    my ( $self, %opts ) = @_;

    my %default  = Provisioner::Cookbook->defaults('zswap');
    my %settings = map { $_ => $opts{$_} // $default{$_} } qw{swap_size compressor zpool max_pool_percent kill_on_pressure protect oomd_omit};

    # bin/new_config compares each setting as a string, so a list goes in as
    # one.  The order of a list does not change what the machine does.
    $settings{$_} = join( ',', sort @{ $settings{$_} } ) for qw{kill_on_pressure protect oomd_omit};

    return %settings;
}

sub template_files {
    return (
        'zswap.tmpfiles.conf.tt'      => 'zswap.tmpfiles.conf',
        'zswap.swapfile.swap.tt'      => 'swapfile.swap',
        'zswap.oomd-swap.conf.tt'     => 'zswap-oomd-swap.conf',
        'zswap.oomd-pressure.conf.tt' => 'zswap-oomd-pressure.conf',
        'zswap.protect.conf.tt'       => 'zswap-protect.conf',
        'zswap.oomd-omit.conf.tt'     => 'zswap-oomd-omit.conf',
    );
}

sub tests {
    return qw{zswap.tt};
}

1;
