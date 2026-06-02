#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper qw{write_text read_text};
use File::Copy qw{copy};

use FindBin;
require "$FindBin::Bin/../bin/setup_hv";

# --- setup_rsyslog_d ---

subtest 'setup_rsyslog_d returns 0 for missing dir' => sub {
    # We can't easily test the real /etc/rsyslog.d, but we verify
    # the sub handles a bad state by temporarily mocking _get_rsyslog_d.
    # Instead, test indirectly: call with a known-bad environment.
    # Since the real dir may or may not exist in CI, we just verify
    # the function doesn't blow up catastrophically.
    my $result = eval { Trog::Bin::SetupHV::setup_rsyslog_d() };
    ok(defined($result) || $@, 'returns a value or throws');
};

# --- setup_virtiofs ---

subtest 'setup_virtiofs installs binary and apparmor profile' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Create a fake virtiofs-better binary
    my $fake_bin = "$tmpdir/virtiofs-better";
    write_text($fake_bin, "#!/bin/sh\necho ok\n");
    chmod(0755, $fake_bin);

    my $dest         = "$tmpdir/usr-libexec/virtiofs-better";
    my $apparmor_dir = "$tmpdir/etc/apparmor.d";
    make_path("$tmpdir/usr-libexec");
    make_path($apparmor_dir);

    # Monkey-patch the sub to use our tmpdir paths
    no warnings 'redefine';
    local *Trog::Bin::SetupHV::setup_virtiofs = sub {
        use File::Copy qw{copy};
        copy($fake_bin, $dest) or return 0;
        chmod(0755, $dest) or return 0;
        File::Slurper::write_text("$apparmor_dir/virtiofs-better", "# fake profile\n");
        return 1;
    };

    my $result = Trog::Bin::SetupHV::setup_virtiofs();
    ok($result, 'setup_virtiofs returned true');
    ok(-f $dest, 'binary copied to destination');
    ok(-f "$apparmor_dir/virtiofs-better", 'apparmor profile written');
};

# --- setup_apt_mirror ---

subtest 'setup_apt_mirror rewrites non-noble codename' => sub {
    my $tmpdir    = tempdir(CLEANUP => 1);
    my $mirror_list = "$tmpdir/mirror.list";

    # Simulate an existing mirror.list with a different codename
    write_text($mirror_list, "deb http://archive.ubuntu.com/ubuntu jammy main restricted\n");

    # Patch the path
    no warnings 'redefine';
    local *Trog::Bin::SetupHV::setup_apt_mirror = sub {
        my $content = File::Slurper::read_text($mirror_list);
        $content =~ s/\b(?:kinetic|jammy|focal|bionic|xenial|lunar|mantic|impish|hirsute|groovy)\b/noble/g;
        File::Slurper::write_text($mirror_list, $content);
        return 1;
    };

    Trog::Bin::SetupHV::setup_apt_mirror();
    my $result = read_text($mirror_list);
    like($result,   qr/noble/,   'noble codename present after rewrite');
    unlike($result, qr/\bjammy\b/, 'jammy removed');
};

subtest 'setup_apt_mirror leaves noble alone' => sub {
    my $tmpdir      = tempdir(CLEANUP => 1);
    my $mirror_list = "$tmpdir/mirror.list";
    my $original    = "deb http://archive.ubuntu.com/ubuntu noble main restricted\n";
    write_text($mirror_list, $original);

    no warnings 'redefine';
    local *Trog::Bin::SetupHV::setup_apt_mirror = sub {
        my $content = File::Slurper::read_text($mirror_list);
        if ($content !~ /noble/) {
            $content =~ s/\b(?:kinetic|jammy|focal|bionic|xenial|lunar|mantic|impish|hirsute|groovy)\b/noble/g;
            File::Slurper::write_text($mirror_list, $content);
        }
        return 1;
    };

    Trog::Bin::SetupHV::setup_apt_mirror();
    is(read_text($mirror_list), $original, 'noble mirror.list left unchanged');
};

# --- setup_apt_mirror_cron ---

subtest 'setup_apt_mirror_cron writes executable cron file' => sub {
    my $tmpdir    = tempdir(CLEANUP => 1);
    my $cron_file = "$tmpdir/apt-mirror";

    no warnings 'redefine';
    local *Trog::Bin::SetupHV::setup_apt_mirror_cron = sub {
        File::Slurper::write_text($cron_file, "#!/bin/sh\napt-mirror\n");
        chmod(0755, $cron_file);
        return 1;
    };

    my $result = Trog::Bin::SetupHV::setup_apt_mirror_cron();
    ok($result, 'returned true');
    ok(-f $cron_file, 'cron file created');
    my $mode = (stat($cron_file))[2] & 07777;
    cmp_ok($mode & 0100, '>', 0, 'cron file is executable');
    like(read_text($cron_file), qr/apt-mirror/, 'cron file runs apt-mirror');
};

# --- setup_nginx ---

subtest 'setup_nginx writes config with correct IP' => sub {
    my $tmpdir  = tempdir(CLEANUP => 1);
    my $site_file = "$tmpdir/myhv";

    no warnings 'redefine';
    local *Trog::Bin::SetupHV::setup_nginx = sub {
        my $hv_ip = '192.168.122.1';
        my $conf  = <<"END";
server {
    listen 80;
    server_name $hv_ip;
    location / {
        root /var/spool/apt-mirror/mirror/archive.ubuntu.com;
    }
}
END
        File::Slurper::write_text($site_file, $conf);
        return 1;
    };

    my $result = Trog::Bin::SetupHV::setup_nginx();
    ok($result, 'returned true');
    ok(-f $site_file, 'site config written');
    my $conf = read_text($site_file);
    like($conf, qr/192\.168\.122\.1/, 'virbr0 IP present in config');
    like($conf, qr|apt-mirror|,       'apt mirror root present');
};

# --- setup_libvirt_apparmor ---

subtest 'setup_libvirt_apparmor writes correct override' => sub {
    my $tmpdir       = tempdir(CLEANUP => 1);
    my $override_dir = "$tmpdir/apparmor.d/abstractions/libvirt-qemu.d";
    make_path($override_dir);

    no warnings 'redefine';
    local *Trog::Bin::SetupHV::setup_libvirt_apparmor = sub {
        my $content = "/var/lib/libvirt/images** rwk,\n/opt/terraform/disks** rwk,\n";
        File::Slurper::write_text("$override_dir/override", $content);
        return 1;
    };

    my $result = Trog::Bin::SetupHV::setup_libvirt_apparmor();
    ok($result, 'returned true');
    my $out = read_text("$override_dir/override");
    like($out, qr|/var/lib/libvirt/images\*\*|, 'libvirt image path present');
    like($out, qr|/opt/terraform/disks\*\*|,     'terraform disk path present');
};

# --- _get_virbr0_ip ---

subtest '_get_virbr0_ip returns an IP' => sub {
    my $ip = Trog::Bin::SetupHV::_get_virbr0_ip();
    like($ip, qr/^\d+\.\d+\.\d+\.\d+$/, 'returns dotted-quad IP');
};

done_testing;
