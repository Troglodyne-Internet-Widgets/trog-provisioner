#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/debug_boot.t - bin/debug_boot: the XML it rewrites, and the grub line it edits

=cut

use Test::More;
use Test::MockModule qw{strict};

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }

# Loaded so that blessing into it in the mocks below is blessing into something
# real, and so Test::MockModule in strict mode has methods to find.
use Trog::HV();    ## no critic (ProhibitUnusedImports)

my $script = "$FindBin::Bin/../bin/debug_boot";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# How many times one string appears in another, without a regex saying so.
sub count_of {
    my ($haystack, $needle) = @_;
    my ($n, $at) = (0, 0);
    $n++ while ($at = index($haystack, $needle, $at) + 1) > 0;
    return $n;
}

# What libvirt hands back, near enough: the serial and console it gives a guest,
# and an <os> with no boot menu in it.
sub domain_xml {
    my (%opt) = @_;
    my $serial = $opt{file}
      ? "<serial type='file'>\n      <source path='$opt{file}'/>\n      <target type='isa-serial' port='0'/>\n    </serial>"
      : "<serial type='pty'>\n      <target type='isa-serial' port='0'/>\n    </serial>";
    my $menu = $opt{bootmenu} ? "<bootmenu enable='yes' timeout='30000'/>" : q{};

    return <<"XML";
<domain type='kvm'>
  <name>vm.test</name>
  <os>$menu
    <type arch='x86_64' machine='pc'>hvm</type>
  </os>
  <devices>
    $serial
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
</domain>
XML
}

# Every one of these drives libvirt; what is under test is the rewriting, so
# libvirt is a place the XML goes and comes back from.
sub with_domain {
    my ($xml, $code) = @_;

    # These are subs in the script, not methods on Trog::HV.
    my %seen = (defined => undef, restarted => 0);
    my $bin = Test::MockModule->new('Trog::Bin::DebugBoot', no_auto => 1);
    $bin->redefine(definition => sub { $xml });
    $bin->redefine(redefine   => sub { $seen{defined} = $_[2]; 1 });
    $bin->redefine(restart    => sub { $seen{restarted}++; 1 });

    $code->(\%seen, $bin);
    return \%seen;
}

subtest 'the console log goes where the guest can be found by name' => sub {
    is(Trog::Bin::DebugBoot::log_path('vm.test'), '/tmp/vm.test-console.log', 'one file per guest');
};

subtest '--console points the serial at a file' => sub {
    my $seen = with_domain(domain_xml(), sub {
        my ($seen, $bin) = @_;
        $bin->redefine(fetch => sub { 0 });
        # Not actually waiting out the boot.
        no warnings 'redefine';    ## no critic (ProhibitNoWarningsRedefine)
        Trog::Bin::DebugBoot::console(bless({}, 'Trog::HV'), 'vm.test', { wait => 0 });
    });

    like($seen->{defined}, qr{<serial type='file'>}, 'the serial is a file now');
    like($seen->{defined}, qr{<source path='/tmp/vm\.test-console\.log'/>}, 'named for the guest');
    unlike($seen->{defined}, qr{<serial type='pty'>}, 'and is no longer a pty');
    is($seen->{restarted}, 1, 'restarted, because the boot we want has not happened yet');
};

subtest '--console refuses a guest already set up for it' => sub {
    my $xml = domain_xml(file => '/tmp/vm.test-console.log');
    eval {
        with_domain($xml, sub {
            Trog::Bin::DebugBoot::console(bless({}, 'Trog::HV'), 'vm.test', { wait => 0 });
        });
    };
    like($@, qr/already logs its console to a file/, 'says so');
    like($@, qr/--fetch/, 'and what to use instead');
};

subtest '--hold adds a boot menu, once' => sub {
    my $seen = with_domain(domain_xml(), sub {
        my ($seen, $bin) = @_;
        $bin->redefine(vnc => sub { 0 });
        Trog::Bin::DebugBoot::hold(bless({}, 'Trog::HV'), 'vm.test', { timeout => 15000 });
    });

    like($seen->{defined}, qr{<bootmenu enable='yes' timeout='15000'/>}, 'with the timeout asked for');
    is($seen->{restarted}, 1, 'and restarted');

    # Adding a second one would make libvirt reject the whole domain.
    my $again = with_domain(domain_xml(bootmenu => 1), sub {
        my ($seen, $bin) = @_;
        $bin->redefine(vnc => sub { 0 });
        Trog::Bin::DebugBoot::hold(bless({}, 'Trog::HV'), 'vm.test', { timeout => 15000 });
    });
    is(count_of($again->{defined}, '<bootmenu'), 1, 'never twice');
};

subtest '--restore undoes both, through what libvirt gives back' => sub {
    # libvirt reformats what it is handed, so the file serial comes back as an
    # element with its source on its own line rather than the one-liner that
    # went in.  Matching the one-liner is how this silently did nothing.
    my $xml = domain_xml(file => '/tmp/vm.test-console.log', bootmenu => 1);

    my $seen = with_domain($xml, sub {
        my ($seen, $bin) = @_;
        $bin->redefine(guest_tool => sub { (q{}, 0) });
        my $hv = Test::MockModule->new('Trog::HV');
        $hv->redefine(vmm => sub { undef });
        Trog::Bin::DebugBoot::restore(bless({}, 'Trog::HV'), 'vm.test');
    });

    like($seen->{defined}, qr{<serial type='pty'>}, 'the serial is a pty again');
    unlike($seen->{defined}, qr{<bootmenu}, 'and the boot menu is gone');
};

# --- The grub edit -------------------------------------------------------------
# virt-edit hands its expression a line with the newline still attached.  A
# trailing \s* eats that, welding the next line on -- which is how this first
# welded grub's initrd directive onto the end of its linux one and left a guest
# with no initrd that did not boot at all.
subtest 'the kernel command line edit leaves the newline alone' => sub {
    my $line = "\tlinux\t/vmlinuz-6.8.0 root=UUID=abc ro  console=ttyS0\n";

    my $add = $line;
    $add =~ s/^([ \t]*linux[ \t]+\S+[^\n]*?)([ \t]+single)?[ \t]*$/$1 single/m;

    like($add, qr/console=ttyS0 single\n\z/, 'single goes on the end of the line');
    like($add, qr/\n\z/, 'and the newline is still there');

    $add =~ s/^([ \t]*linux[ \t]+\S+[^\n]*?)([ \t]+single)?[ \t]*$/$1 single/m;
    is(count_of($add, 'single'), 1, 'running it twice does not say it twice');

    my $removed = $add;
    $removed =~ s/^([ \t]*linux[ \t]+[^\n]*?)[ \t]+single[ \t]*$/$1/m;
    is($removed, $line, 'and taking it off again gives back exactly what we started with');
};

subtest 'the vnc port comes off the display libvirt names' => sub {
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine(capture    => sub { "vnc://127.0.0.1:10\n" });
    $hv->redefine(ssh_target => sub { 'doge@hv.example.net' });

    open(my $capture, '>', \my $out) or die $!;
    do { local *STDOUT = $capture; Trog::Bin::DebugBoot::vnc(bless({}, 'Trog::HV'), 'vm.test') };
    close $capture;

    is($out, "5910\n", 'display 10 is port 5910');
};

done_testing();
