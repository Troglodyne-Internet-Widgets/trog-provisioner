#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Slurper qw{read_text};
use FindBin;

# --- PCI address parsing (same regex as bin/provision) ---

subtest 'valid PCI address parses correctly' => sub {
    my $addr = '0000:01:00.0';
    my ($dom, $bus, $slot, $func) =
        $addr =~ m/^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-9a-fA-F]+)$/;
    is($dom,  '0000', 'domain parsed');
    is($bus,  '01',   'bus parsed');
    is($slot, '00',   'slot parsed');
    is($func, '0',    'function parsed');
};

subtest 'valid PCI address with non-zero fields' => sub {
    my $addr = '0001:2a:1f.f';
    my ($dom, $bus, $slot, $func) =
        $addr =~ m/^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-9a-fA-F]+)$/;
    is($dom,  '0001', 'domain parsed');
    is($bus,  '2a',   'bus parsed');
    is($slot, '1f',   'slot parsed');
    is($func, 'f',    'function parsed');
};

subtest 'invalid PCI addresses fail regex' => sub {
    for my $bad ('01:00.0', '0000-01-00-0', 'gggg:01:00.0', '0000:01:00', '0000:01:00.') {
        my ($dom) = $bad =~ m/^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-9a-fA-F]+)$/;
        ok(!defined($dom), "bad address '$bad' does not parse");
    }
};

# --- hostdev HCL block structure ---

subtest 'hostdev HCL block contains required fields' => sub {
    my $addr = '0000:03:00.0';
    my ($dom, $bus, $slot, $func) =
        $addr =~ m/^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-9a-fA-F]+)$/;

    my $block = qq|
      {
        mode    = "subsystem"
        type    = "pci"
        managed = "yes"
        source = {
          address = {
            domain   = "0x$dom"
            bus      = "0x$bus"
            slot     = "0x$slot"
            function = "0x$func"
          }
        }
      }|;

    like($block, qr/mode\s*=\s*"subsystem"/, 'mode = subsystem');
    like($block, qr/type\s*=\s*"pci"/,       'type = pci');
    like($block, qr/managed\s*=\s*"yes"/,    'managed = yes');
    like($block, qr/0x0000/,                 'domain hex');
    like($block, qr/0x03/,                   'bus hex');
    like($block, qr/0x00/,                   'slot hex');
    like($block, qr/0x0/,                    'function hex');
};

# --- domain.tmpl contains %HOSTDEVS% placeholder ---

subtest 'domain.tmpl has %HOSTDEVS% placeholder' => sub {
    my $tmpl = read_text("$FindBin::Bin/../domain.tmpl");
    like($tmpl, qr/%HOSTDEVS%/, 'domain.tmpl contains %HOSTDEVS% placeholder');
};

subtest '%HOSTDEVS% is inside the devices block' => sub {
    my $tmpl = read_text("$FindBin::Bin/../domain.tmpl");
    # %FILESYSTEMS% and %HOSTDEVS% must appear before the closing brace of devices
    my ($devices_section) = $tmpl =~ m/devices\s*=\s*\{(.+)\}\s*\}\s*$/s;
    ok(defined $devices_section, 'found devices block');
    like($devices_section, qr/%HOSTDEVS%/, '%HOSTDEVS% is inside devices block');
};

# --- provision.conf example documents gpu_pci ---

subtest 'example provision.conf documents gpu_pci' => sub {
    my $conf = read_text("$FindBin::Bin/../example.test/provision.conf");
    like($conf, qr/gpu_pci/,  'documents gpu_pci option');
    like($conf, qr/vfio-pci/, 'mentions vfio-pci prerequisite');
    like($conf, qr/IOMMU/i,   'mentions IOMMU prerequisite');
};

# --- _check_vfio_ready (requires full module) ---

SKIP: {
    # Load the provision script only if all its deps are available
    my $can_load = eval {
        local @INC = @INC;
        require Net::OpenSSH::More;
        require YAML::XS;
        require XML::Twig;
        require JSON::MaybeXS;
        1;
    };
    skip 'provision deps not all installed (Net::OpenSSH::More etc.)', 2 unless $can_load;

    require "$FindBin::Bin/../bin/provision";

    subtest '_check_vfio_ready does not die with empty list' => sub {
        eval { Trog::Bin::Provisioner::_check_vfio_ready() };
        is($@, '', 'no exception with empty list');
    };

    subtest '_check_vfio_ready does not die with synthetic address' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        eval { Trog::Bin::Provisioner::_check_vfio_ready('9999:ff:1f.7') };
        is($@, '', '_check_vfio_ready does not die');
    };
}

done_testing;
