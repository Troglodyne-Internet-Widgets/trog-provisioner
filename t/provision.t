#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper qw{write_text};

use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require XML::Twig; require Net::OpenSSH::More; require Net::EmptyPort; 1 }
      or plan skip_all => "provisioner prereqs not installed: $@";
}

require "$FindBin::Bin/../bin/provision";
require Config::Simple;
require Trog::HV;

# --- terraform state is kept per-hypervisor ----------------------------------
subtest 'tf_dir_for' => sub {
    my $local = Trog::HV->new();
    is(Trog::Bin::Provisioner::tf_dir_for($local), '/opt/terraform',
        'the default HV keeps using the historical path');

    is(Trog::Bin::Provisioner::tf_dir_for(Trog::HV->new(uri => 'qemu:///system')),
        '/opt/terraform', 'so does an explicit qemu:///system');

    my $remote = Trog::HV->new(uri => 'qemu+ssh://root@hv1.example.net/system');
    is(Trog::Bin::Provisioner::tf_dir_for($remote),
        '/opt/terraform/hv/qemu_ssh_root_hv1_example_net_system',
        'a remote HV gets its own state tree so the two never cross-destroy');

    isnt(Trog::Bin::Provisioner::tf_dir_for($remote),
         Trog::Bin::Provisioner::tf_dir_for(Trog::HV->new(uri => 'qemu+ssh://root@hv2.example.net/system')),
         'two remote HVs do not share state');

    is(Trog::Bin::Provisioner::tf_dir_for($remote, '/somewhere/else'), '/somewhere/else',
        '--tfdir wins');
};

# --- which address we SSH to on the guest ------------------------------------
subtest 'guest_ssh_ip' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $with_ip = "$dir/with.conf";
    write_text($with_ip, "ips=203.0.113.10\n");
    my $conf_with = Config::Simple->new($with_ip);

    my $without = "$dir/without.conf";
    write_text($without, "size=42949672960\n");
    my $conf_without = Config::Simple->new($without);

    {
        local $Trog::Bin::Provisioner::hv = Trog::HV->new();
        is(Trog::Bin::Provisioner::guest_ssh_ip($conf_with, '192.168.122.50'), '192.168.122.50',
            'a local HV uses the NAT lease, as it always did');
        is(Trog::Bin::Provisioner::guest_ssh_ip($conf_without, '192.168.122.50'), '192.168.122.50',
            'even with no static IP configured');
    }

    {
        local $Trog::Bin::Provisioner::hv = Trog::HV->new(uri => 'qemu+ssh://hv1/system');
        is(Trog::Bin::Provisioner::guest_ssh_ip($conf_with, '192.168.122.50'), '203.0.113.10',
            'a remote HV uses the bridged static IP, which we can actually route to');

        eval { Trog::Bin::Provisioner::guest_ssh_ip($conf_without, '192.168.122.50') };
        like($@, qr/requires the guest to have a/, 'and says so when there is none');
        like($@, qr/\bips\b/, 'naming the config key to set');
    }
};

done_testing;
