package Trog::HV::Libvirt::BridgeHelper;

#ABSTRACT: qemu-bridge-helper, its ACL in /etc/qemu/bridge.conf, and the capability it runs with

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

use File::Basename();
use List::Util();

=head1 NAME

Trog::HV::Libvirt::BridgeHelper - qemu-bridge-helper, its ACL in
/etc/qemu/bridge.conf, and the capability it runs with

=head1 SYNOPSIS

    use Trog::HV::Libvirt::BridgeHelper();

    my @steps = (
        Trog::HV::Libvirt::BridgeHelper::grant_steps( $hv, 'runner', qw{virbr0 virbr1} ),
        Trog::HV::Libvirt::BridgeHelper::capability_steps( $hv, $helper ),
    );

    my $rules   = Trog::HV::Libvirt::BridgeHelper::rules( sub ($file) { $hv->read_text($file) } );
    my @refused = Trog::HV::Libvirt::BridgeHelper::refused( $rules, qw{virbr0 virbr1} );

=head1 DESCRIPTION

Everything here is about one program of QEMU and the file that it reads.  None
of it is about addresses: which bridge a guest is on, and what address it gets
there, is the business of L<Trog::HV/static_pools> and L<Provisioner::IPPool>.
This module only decides whether an account may put a guest on a bridge at all.

=head2 Why there is a bridge helper at all

A runner account builds its guests in its own session of libvirt, and not on
the system daemon, because the C<libvirt> group that the system daemon needs is
as good as root.  L<Trog::HV::Libvirt/RUNNER ACCOUNTS> has the whole argument.

A session daemon runs as the account, and the account cannot make a tap device
or add one to a bridge.  So libvirt hands that job to C<qemu-bridge-helper>.  A
guest of a session gets an interface of the type C<bridge>, and qemu runs the
helper with the name of the bridge.  The helper makes the tap device, adds it
to the bridge, and passes the descriptor back.  It needs C<CAP_NET_ADMIN> for
that, and it is the one program here that has it.

=head2 Why it needs a capability, and an apt hook

Ubuntu installs the helper without setuid and without a capability, so it can
do nothing for a user who is not root.  L</capability_steps> gives it
C<cap_net_admin>, and writes an apt hook that sets the capability again after
each upgrade of the package, because the new file has none.

The capability lets each user who can run the helper add a tap device to a
bridge that the ACL allows, and no other bridge.  So the ACL is the only thing
that decides which bridges an account reaches.

=head2 Why this edits /etc/qemu/bridge.conf by hand

The helper reads its ACL from F</etc/qemu/bridge.conf> each time that it runs.
It denies every bridge unless a line allows it.  QEMU ships no tool that
reads or writes the file, and documents none of its syntax.  The header of
F<qemu-bridge-helper.c> says so: "There is no manual page" and "The syntax of
the ACL file is not documented anywhere".  So this module has its own reader
and writer, and what they know of the syntax comes from that source:

=over 4

=item * A line is C<allow BRIDGE>, C<allow all>, C<deny BRIDGE>, C<deny all>,
C<include FILE>, a comment that starts with C<#>, or empty.

=item * The helper allows a bridge when an C<allow> line names it or C<all>,
and no C<deny> line does.  A C<deny> wins wherever it is.

=item * C<include> names one file, with no glob, so there is no F<conf.d>.

=item * In F<bridge.conf> itself, a line that the helper cannot read makes it
fail, and then no guest of any session on the host gets onto a bridge.  In a
file that it includes, the helper keeps the lines above the bad one and drops
the rest, with a message that nobody sees.

=back

So each account gets a file of its own, F</etc/qemu/trog-runner-USER.conf>,
which this module owns whole, and one C<include> line for it in
F<bridge.conf>.  That line is the only change to the file that the
distribution and the administrator own.  This module writes only plain
C<allow> and C<include> lines, and it rewrites F<bridge.conf> through
L<Trog::Machine/rewrite_lines>, which refuses to write from a read that failed.

configd, which gives a file without a F<conf.d> one, does not fit here.  It
builds the file when a service starts, and no service reads this file: qemu
runs the helper each time that it starts a guest.

=cut

=head1 PATHS

The files and the places of the helper, as package variables so that a test can
move them.

=over 4

=item C<$CONF>

F</etc/qemu/bridge.conf>, the file that the helper reads first.

=item C<@HELPERS>

Where a distribution puts the helper, in the order that L</helper> looks.

=item C<$APT_HOOK>

The apt hook of L</capability_steps>.

=back

=cut

our $CONF     = '/etc/qemu/bridge.conf';
our @HELPERS  = qw{/usr/lib/qemu/qemu-bridge-helper /usr/libexec/qemu-bridge-helper};
our $APT_HOOK = '/etc/apt/apt.conf.d/90trog-qemu-bridge-helper';

=head1 FUNCTIONS

=head2 acl_file

C<($user)>.  F</etc/qemu/trog-runner-USER.conf>, the ACL of the account C<$user>.

=cut

sub acl_file ($user) { return "/etc/qemu/trog-runner-$user.conf" }

=head2 helper

C<($hv)>.  The first of C<@HELPERS> that the hypervisor C<$hv> has, or undef.

=cut

sub helper ($hv) {
    return List::Util::first { $hv->file_exists($_) } @HELPERS;
}

=head2 rules

C<($read)>.  What the helper reads, as an array reference of C<[$verb, $bridge]>, where the
verb is C<allow> or C<deny> and the bridge can be C<all>.  C<$read> is a code
reference that takes a path and returns the text of the file, or undef when it
cannot read it.  It starts with C<$CONF> and follows each C<include>.

Dies when it cannot read a file, naming it, and when the includes go on past
32 files, which a loop of includes does.  The helper ignores a file that it
cannot read.  This does not, because a check that cannot read a file cannot
say what the helper allows.

=cut

sub rules ($read) {
    my ( @rules, @files );
    my @to_read = ($CONF);
    while ( defined( my $file = shift @to_read ) ) {
        push @files, $file;
        die "$CONF includes more files than this reads: " . join( ', ', @files ) . "\n" if @files > 32;

        my $text = $read->($file) // die "Could not read $file\n";
        foreach my $line ( split m/\n/, $text ) {
            my ( $verb, $what ) = $line =~ m/\A \s* (allow|deny|include) \s+ (\S+)/ or next;
            if   ( $verb eq 'include' ) { push @to_read, $what }
            else                        { push @rules,   [ $verb, $what ] }
        }
    }
    return \@rules;
}

=head2 refused

C<($rules, @bridges)>.  Each of C<@bridges> that C<$rules>, from L</rules>, do not let a user join: one
that no C<allow> line names, by its name or by C<all>, and one that a C<deny>
line names.

=cut

sub refused ( $rules, @bridges ) {
    my $says = sub ( $verb, $bridge ) {
        List::Util::any { $_->[0] eq $verb && ( $_->[1] eq 'all' || $_->[1] eq $bridge ) } @$rules;
    };
    return grep { !$says->( 'allow', $_ ) || $says->( 'deny', $_ ) } @bridges;
}

=head2 grant_steps

C<($hv, $user, @bridges)>.  The actions, for L<Trog::Steps/run>, that let C<$user> put the guests of its
session on each of C<@bridges>, in order:

=over 4

=item 1. An C<allow> line for each bridge in L</acl_file>.  A line that is
there already stays, also for a bridge that is not in C<@bridges>.  So
C<runner_account_steps> in L<Trog::HV::Libvirt> and F<bin/guest_network> each
add their bridges, and neither takes away the bridge of the other.

=item 2. An C<include> of that file in C<$CONF>.

=back

=cut

sub grant_steps ( $hv, $user, @bridges ) {
    my $acl     = acl_file($user);
    my $include = "include $acl";

    my $missing = sub {
        my %has = map { $_ => 1 } split m/\n/, $hv->root_text($acl);
        return grep { !$has{$_} } map { "allow $_" } @bridges;
    };

    return (
        {
            what => "let $user join " . join( ' and ', @bridges ) . " in $acl",
            done => sub { !$missing->() },
            do   => sub {
                $hv->run_sudo_or_die( qw{install -d -m 0755}, File::Basename::dirname($acl) );
                $hv->rewrite_lines( $acl, keep => sub ($line) { $line ne q{} }, add => [ $missing->() ] );
            },
        },
        {
            what => "include $acl in $CONF",
            done => sub { $hv->holds_line( $CONF, $include ) },
            do   => sub {
                $hv->rewrite_lines( $CONF, keep => sub ($line) { $line ne $include }, add => [$include] );
            },
        },
    );
}

=head2 revoke_steps

C<($hv, $user)>.  The actions that undo L</grant_steps> for C<$user>: the C<include> line goes
out of C<$CONF>, and then L</acl_file> goes.  A C<$CONF> that root cannot read
looks to these like one without the line, so it stays as it was.

=cut

sub revoke_steps ( $hv, $user ) {
    my $acl     = acl_file($user);
    my $include = "include $acl";
    return (
        {
            what => "take $acl out of $CONF",
            done => sub { !$hv->holds_line( $CONF, $include ) },
            do   => sub {
                $hv->rewrite_lines( $CONF, keep => sub ($line) { $line ne $include } );
            },
        },
        {
            what => "remove $acl",
            done => sub { !$hv->file_exists($acl) },
            do   => sub { $hv->run_sudo_or_die( qw{rm -f}, $acl ) },
        },
    );
}

=head2 capability_steps

C<($hv, $helper)>.  The actions that let the helper at C<$helper>, from L</helper>, add a tap
device to a bridge: C<cap_net_admin> on it, and C<$APT_HOOK>, which sets the
capability again after each upgrade of the package.  The hook needs apt, which
a caller makes sure of first.

=cut

sub capability_steps ( $hv, $helper ) {
    my $hook = join "\n", '// Written by trog-provisioner for the runner accounts on this hypervisor.  A new',
      '// qemu package puts back a qemu-bridge-helper without the capability that lets', '// an account put the guests of its session on a bridge.  See',
      '// Trog::HV::Libvirt::BridgeHelper.',                                             qq{DPkg::Post-Invoke { "if [ -e $helper ]; then setcap cap_net_admin+ep $helper; fi"; };};

    return (
        {
            what => "give $helper the capability cap_net_admin",
            done => sub { has_capability( $hv, $helper ) },
            do   => sub { $hv->run_sudo_or_die( qw{setcap cap_net_admin+ep}, $helper ) },
        },
        {
            what => "set it again after each upgrade, in $APT_HOOK",
            done => sub { $hv->root_text($APT_HOOK) eq $hook },
            do   => sub { $hv->write_text( $APT_HOOK, "$hook\n", sudo => 1, mode => '0644' ) or die "Could not write $APT_HOOK\n" },
        },
    );
}

=head2 capability_removal_steps

C<($hv, $helper, $user)>.  The actions that undo L</capability_steps> when C<$user> is the last runner
account on the hypervisor, and do nothing while L</acl_file> of another one is
there, because that account still needs the helper.  Without a C<$helper> there
is no capability to take away, and only the hook goes.

=cut

sub capability_removal_steps ( $hv, $helper, $user ) {
    my $own  = File::Basename::basename( acl_file($user) );
    my $dir  = File::Basename::dirname( acl_file($user) );
    my $last = sub {
        !List::Util::any { m/\Atrog-runner-.+[.]conf\z/ && $_ ne $own } $hv->list_dir($dir);
    };

    return (
        {
            what => "remove $APT_HOOK, unless another runner account needs it",
            done => sub { !$last->() || !$hv->file_exists($APT_HOOK) },
            do   => sub { $hv->run_sudo_or_die( qw{rm -f}, $APT_HOOK ) },
        },
        (
            $helper
            ? {
                what => "take cap_net_admin away from $helper, unless another runner account needs it",
                done => sub { !$last->() || !has_capability( $hv, $helper ) },
                do   => sub { $hv->run_sudo_or_die( qw{setcap -r}, $helper ) },
              }
            : ()
        ),
    );
}

=head2 has_capability

C<($hv, $helper)>.  True when C<getcap> says that the helper at C<$helper>, one of C<@HELPERS>,
has C<cap_net_admin>.

=cut

sub has_capability ( $hv, $helper ) {
    return ( $hv->capture_cmd("getcap '$helper' 2>/dev/null") // q{} ) =~ m/cap_net_admin/;
}

=head1 SEE ALSO

L<Trog::HV::Libvirt/RUNNER ACCOUNTS>, L<Trog::HV::Libvirt/check_bridge_acl>,
F<qemu-bridge-helper.c> in the source of QEMU.

=cut

1;
