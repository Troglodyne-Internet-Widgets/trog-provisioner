#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper qw{read_text write_text};

use FindBin();
use FindBin::libs;
use Trog::HV();

# Every subtest wants a hypervisor of its own, and new() hands back the last one
# it built unless you ask for something different.
sub fresh {
    Trog::HV->forget();
    return Trog::HV->new(@_);
}

# --- Defaults: no URI means we are the hypervisor -----------------------------
subtest 'default connection is local' => sub {
    my $hv = fresh();
    is($hv->uri, 'qemu:///system', 'defaults to qemu:///system');
    ok($hv->is_local,  'is_local');
    ok(!$hv->explicit, 'not explicit, so libvirt resolves its own default');
    is($hv->_wrap('brctl show'), 'brctl show', 'local commands run unwrapped');
    is($hv->ssh_target, undef, 'no ssh target');
};

subtest 'new() is a singleton' => sub {
    my $configured = fresh(uri => 'qemu+ssh://root@hv1.example.net/system');
    is(Trog::HV->new()->uri, 'qemu+ssh://root@hv1.example.net/system',
        'a later new() with no arguments finds the hypervisor we configured');
    is(Trog::HV->new(), $configured, 'and it is the very same object');

    my $other = Trog::HV->new(uri => 'qemu+ssh://root@hv2.example.net/system');
    isnt($other, $configured, 'asking for a different URI builds a different one');
    is(Trog::HV->new()->uri, 'qemu+ssh://root@hv2.example.net/system',
        'which becomes the one everything else sees');
};

subtest 'explicitly asking for the local URI is still explicit' => sub {
    my $hv = fresh(uri => 'qemu:///system');
    ok($hv->is_local, 'still local');
    ok($hv->explicit, 'explicit');
};

# --- URI parsing --------------------------------------------------------------
subtest 'qemu+ssh URI' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@hv1.example.net/system');
    ok(!$hv->is_local, 'remote');
    is($hv->ssh_target, 'root@hv1.example.net', 'ssh target');
    is($hv->ssh_user,   'root',                 'ssh user');
    is($hv->ssh_port,   undef,                  'no explicit port');
    is($hv->_wrap(q{brctl show | grep foo}),
        q{ssh -o BatchMode=yes root@hv1.example.net 'brctl show | grep foo'},
        'shell commands are wrapped in ssh');
};

subtest 'qemu+ssh URI with a port' => sub {
    my $hv = fresh(uri => 'qemu+ssh://admin@10.0.0.5:2222/system');
    is($hv->ssh_target, 'admin@10.0.0.5', 'ssh target');
    is($hv->ssh_port,   2222,             'port from URI');
    like($hv->_wrap('id -un'), qr/-p 2222/, 'port forwarded to ssh');
};

subtest 'bracketed IPv6 host' => sub {
    my $hv = fresh(uri => 'qemu+libssh2://[fe80::1]:22/system');
    is($hv->ssh_host, 'fe80::1', 'host unbracketed');
    is($hv->ssh_port, 22,        'port');
};

subtest 'unparseable URI dies' => sub {
    Trog::HV->forget();
    eval { Trog::HV->new(uri => 'not a uri') };
    like($@, qr/Could not parse libvirt connection URI/, 'dies loudly');
};

# --- Transports that give us no shell ----------------------------------------
subtest 'a remote transport with no shell is refused up front' => sub {
    Trog::HV->forget();
    eval { Trog::HV->new(uri => 'qemu+tcp://hv2.example.net/system') };
    like($@, qr/gives us no shell/,  'tcp:// is rejected rather than half-working');
    like($@, qr/qemu\+ssh:\/\/root/, 'and names the transport to use instead');
};

# --- Quoting ------------------------------------------------------------------
subtest 'shell metacharacters survive the round trip' => sub {
    my $hv = fresh(uri => 'qemu+ssh://hv/system');
    my $nasty = q{echo 'it'\''s fine'; rm -rf /};
    my $wrapped = $hv->_wrap($nasty);
    like($wrapped, qr/\Assh /, 'wrapped');
    # Everything after the target is one single-quoted argument.
    my ($payload) = $wrapped =~ m/hv (.*)\z/;
    is(_unshq($payload), $nasty, 'payload survives quoting intact');
};

sub _unshq {
    my ($str) = @_;
    $str =~ s/\A'//;
    $str =~ s/'\z//;
    $str =~ s/'\\''/'/g;
    return $str;
}

# --- Slug ---------------------------------------------------------------------
subtest 'slug is filesystem safe and stable' => sub {
    is(fresh(uri => 'qemu:///system')->slug, 'qemu_system', 'local');
    is(fresh(uri => 'qemu+ssh://root@hv1.example.net/system')->slug,
        'qemu_ssh_root_hv1_example_net_system', 'remote');
    unlike(fresh(uri => 'qemu+ssh://root@hv1/system')->slug, qr{[^A-Za-z0-9_]},
        'no path separators');
};

# --- Paths --------------------------------------------------------------------
subtest 'terraform state is kept per-hypervisor' => sub {
    is(fresh()->tf_dir, '/opt/terraform',
        'the default hypervisor keeps using the historical path');
    is(fresh(uri => 'qemu:///system')->tf_dir, '/opt/terraform',
        'so does an explicit qemu:///system');

    my $remote = fresh(uri => 'qemu+ssh://root@hv1.example.net/system');
    is($remote->tf_dir, '/opt/terraform/hv/qemu_ssh_root_hv1_example_net_system',
        'a remote hypervisor gets its own state tree so the two never cross-destroy');
    is($remote->tf_config_dir, $remote->tf_dir . '/config', 'tf_config_dir hangs off it');

    isnt($remote->tf_dir, fresh(uri => 'qemu+ssh://root@hv2.example.net/system')->tf_dir,
        'two remote hypervisors do not share state');

    is(fresh(uri => 'qemu+ssh://root@hv1.example.net/system', tf_dir => '/somewhere/else')->tf_dir,
        '/somewhere/else', '--tfdir wins');
};

subtest 'pool and domain paths default the way they always did' => sub {
    my $hv = fresh();
    is($hv->pool_path,  '/opt/terraform/disks', 'pool_path');
    is($hv->domain_dir, '/opt/domains',         'domain_dir');

    my $set = fresh(uri => 'qemu+ssh://hv/system', pool_path => '/srv/pool', domain_dir => '/srv/domains');
    is($set->pool_path,  '/srv/pool',    'pool_path override');
    is($set->domain_dir, '/srv/domains', 'domain_dir override');
};

# --- Which address we SSH to on the guest ------------------------------------
subtest 'guest_ssh_ip' => sub {
    require Config::Simple;
    my $dir = tempdir(CLEANUP => 1);

    write_text("$dir/with.conf", "ips=203.0.113.10\n");
    my $conf_with = Config::Simple->new("$dir/with.conf");

    write_text("$dir/without.conf", "size=42949672960\n");
    my $conf_without = Config::Simple->new("$dir/without.conf");

    my $local = fresh();
    is($local->guest_ssh_ip($conf_with, '192.168.122.50'), '192.168.122.50',
        'a local hypervisor uses the NAT lease, as it always did');
    is($local->guest_ssh_ip($conf_without, '192.168.122.50'), '192.168.122.50',
        'even with no static IP configured');

    my $remote = fresh(uri => 'qemu+ssh://hv1/system');
    is($remote->guest_ssh_ip($conf_with, '192.168.122.50'), '203.0.113.10',
        'a remote hypervisor uses the bridged static IP, which we can actually route to');

    eval { $remote->guest_ssh_ip($conf_without, '192.168.122.50') };
    like($@, qr/requires the guest to have a/, 'and says so when there is none');
    like($@, qr/\bips\b/, 'naming the config key to set');
};

# --- Local file operations degrade to plain filesystem calls ------------------
subtest 'local file helpers' => sub {
    my $hv  = fresh();
    my $dir = tempdir(CLEANUP => 1);

    ok(!$hv->file_exists_hv("$dir/nope"), 'file_exists_hv false for missing');
    ok($hv->mkpath_hv("$dir/a/b/c"),      'mkpath_hv');
    ok(-d "$dir/a/b/c",                   'directory made');

    $hv->write_text_hv("$dir/f", "hello\n");
    ok($hv->file_exists_hv("$dir/f"), 'file_exists_hv true after write');
    is($hv->read_text_hv("$dir/f"), "hello\n", 'read_text_hv');

    $hv->unlink_hv("$dir/f");
    ok(!-f "$dir/f", 'unlink_hv');
};

subtest 'append_line_hv does not duplicate' => sub {
    my $hv  = fresh();
    my $dir = tempdir(CLEANUP => 1);
    my $ak  = "$dir/.ssh/authorized_keys";

    $hv->append_line_hv($ak, 'ssh-rsa AAAA one');
    $hv->append_line_hv($ak, 'ssh-rsa BBBB two');
    $hv->append_line_hv($ak, 'ssh-rsa AAAA one');

    my @lines = split(/\n/, read_text($ak));
    is(scalar(@lines), 2, 'the repeated key was only written once');
    is_deeply(\@lines, ['ssh-rsa AAAA one', 'ssh-rsa BBBB two'], 'in order');
};

subtest 'the transfer user is us when the hypervisor is us' => sub {
    my $hv = fresh();
    is($hv->hv_user, scalar getpwuid($<), 'local transfer user is the caller');
    is($hv->authorized_keys, "$ENV{HOME}/.ssh/authorized_keys", 'and our own authorized_keys');
};

# --- from_config --------------------------------------------------------------
subtest 'from_config reads provision.conf, the command line wins' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/provision.conf";
    write_text($file, join("\n", qw{
        libvirt_uri=qemu+ssh://confuser@confhv/system
        pool_path=/srv/pool
        domain_dir=/srv/domains
        bridge_device=br7
    }) . "\n");

    require Config::Simple;
    my $config = Config::Simple->new($file);

    Trog::HV->forget();
    my $from_conf = Trog::HV->from_config($config);
    is($from_conf->uri,           'qemu+ssh://confuser@confhv/system', 'uri from config');
    is($from_conf->ssh_target,    'confuser@confhv',                   'ssh host/user inferred from it');
    is($from_conf->pool_path,     '/srv/pool',                         'pool_path from config');
    is($from_conf->domain_dir,    '/srv/domains',                      'domain_dir from config');
    is($from_conf->bridge_device, 'br7',                               'bridge_device from config, no probing');

    my $overridden = Trog::HV->from_config($config, uri => 'qemu+ssh://cli/system');
    is($overridden->uri, 'qemu+ssh://cli/system', '--connect beats config');

    Trog::HV->forget();
    ok(Trog::HV->from_config(undef)->is_local, 'a missing config is just the local hypervisor');
};

# --- Remote path, exercised against a stand-in for ssh ------------------------
#
# The fake ssh drops the flags and hands the command to /bin/sh exactly the way
# a real one does, so this proves the two levels of quoting actually survive.
subtest 'remote commands round-trip through ssh' => sub {
    my $bin = tempdir(CLEANUP => 1);
    write_text("$bin/ssh", <<'SH');
#!/bin/bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-p) shift 2;;
    *) args+=("$1"); shift;;
  esac
done
unset 'args[0]'
exec /bin/sh -c "${args[*]}"
SH
    chmod 0755, "$bin/ssh";

    # ...and a stand-in for scp, which just strips the host: prefix.
    write_text("$bin/scp", <<'SH');
#!/bin/bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -q) shift;;
    -o|-P) shift 2;;
    *) args+=("$1"); shift;;
  esac
done
src="${args[0]}"
dest="${args[1]#*:}"
exec cp "$src" "$dest"
SH
    chmod 0755, "$bin/scp";
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my $hv  = fresh(uri => 'qemu+ssh://root@fakehv/system');
    my $dir = tempdir(CLEANUP => 1);

    is($hv->qx_hv(q{echo 'one two' | tr a-z A-Z}), "ONE TWO\n",
        'a shell pipeline survives intact');

    is($hv->system_hv(qw{test -d}, $dir), 0, 'system_hv argv reaches the far side');
    isnt($hv->system_hv(qw{test -d}, "$dir/nope"), 0, 'and its exit code comes back');

    ok(!$hv->file_exists_hv("$dir/f"), 'file_exists_hv false for missing');
    $hv->write_text_hv("$dir/f", "written remotely\n");
    ok($hv->file_exists_hv("$dir/f"), 'file_exists_hv true after write');
    is($hv->read_text_hv("$dir/f"), "written remotely\n", 'read_text_hv');

    ok($hv->mkpath_hv("$dir/x/y"), 'mkpath_hv');
    ok(-d "$dir/x/y", 'nested dir made');

    $hv->unlink_hv("$dir/f");
    ok(!-f "$dir/f", 'unlink_hv');

    write_text("$dir/src", "payload\n");
    ok($hv->put_file("$dir/src", "$dir/dst"), 'put_file');
    is(read_text("$dir/dst"), "payload\n", 'the file landed on the far side');

    # The whole domain directory has to make it across, not just the tarball.
    my $tree = tempdir(CLEANUP => 1);
    mkdir "$tree/src";
    write_text("$tree/src/data.tar.gz", "tarball\n");
    write_text("$tree/src/users.yaml",  "users: []\n");
    ok($hv->put_dir("$tree/src", "$tree/dst"), 'put_dir');
    is(read_text("$tree/dst/data.tar.gz"), "tarball\n",   'payload landed');
    is(read_text("$tree/dst/users.yaml"),  "users: []\n", 'and so did everything beside it');

    # Quoting hazards: spaces, single quotes, globs, and shell metacharacters
    # all have to arrive verbatim.
    my $nasty = "a b\tc 'quoted' \$HOME * ; rm -rf /";
    my $ak    = "$dir/keys/authorized_keys";
    $hv->append_line_hv($ak, $nasty);
    $hv->append_line_hv($ak, $nasty);
    is(read_text($ak), "$nasty\n", 'nasty line written once, verbatim');
};

done_testing;
