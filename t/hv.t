#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper qw{read_text write_text};

use FindBin;
use lib "$FindBin::Bin/../lib";
use Trog::HV();

# --- Defaults: no URI means we are the hypervisor -----------------------------
subtest 'default connection is local' => sub {
    my $hv = Trog::HV->new();
    is($hv->uri, 'qemu:///system', 'defaults to qemu:///system');
    ok($hv->is_local,  'is_local');
    ok(!$hv->explicit, 'not explicit');
    is_deeply([$hv->virsh_argv('list', '--all')], [qw{virsh list --all}],
        'no -c passed when the user never asked for a specific HV');
    is($hv->_wrap('brctl show'), 'brctl show', 'local commands run unwrapped');
    is($hv->ssh_target, undef, 'no ssh target');
};

subtest 'explicitly asking for the local URI still passes -c' => sub {
    my $hv = Trog::HV->new(uri => 'qemu:///system');
    ok($hv->is_local, 'still local');
    ok($hv->explicit, 'explicit');
    is_deeply([$hv->virsh_argv('list')], ['virsh', '-c', 'qemu:///system', 'list'],
        '-c passed through');
};

# --- URI parsing --------------------------------------------------------------
subtest 'qemu+ssh URI' => sub {
    my $hv = Trog::HV->new(uri => 'qemu+ssh://root@hv1.example.net/system');
    ok(!$hv->is_local, 'remote');
    is($hv->ssh_target, 'root@hv1.example.net', 'ssh target');
    is($hv->ssh_user,   'root',                 'ssh user');
    is($hv->ssh_port,   undef,                  'no explicit port');
    is($hv->_wrap(q{brctl show | grep foo}),
        q{ssh -o BatchMode=yes root@hv1.example.net 'brctl show | grep foo'},
        'shell commands are wrapped in ssh');
};

subtest 'qemu+ssh URI with a port' => sub {
    my $hv = Trog::HV->new(uri => 'qemu+ssh://admin@10.0.0.5:2222/system');
    is($hv->ssh_target, 'admin@10.0.0.5', 'ssh target');
    is($hv->ssh_port,   2222,             'port from URI');
    like($hv->_wrap('id -un'), qr/-p 2222/, 'port forwarded to ssh');
};

subtest 'bracketed IPv6 host' => sub {
    my $hv = Trog::HV->new(uri => 'qemu+libssh2://[fe80::1]:22/system');
    is($hv->ssh_host, 'fe80::1', 'host unbracketed');
    is($hv->ssh_port, 22,        'port');
};

subtest 'unparseable URI dies' => sub {
    eval { Trog::HV->new(uri => 'not a uri') };
    like($@, qr/Could not parse libvirt connection URI/, 'dies loudly');
};

# --- Transports that give us no shell ----------------------------------------
subtest 'tcp transport has no shell without an override' => sub {
    my $hv = Trog::HV->new(uri => 'qemu+tcp://hv2.example.net/system');
    ok(!$hv->is_local,   'remote');
    is($hv->ssh_target, undef, 'no ssh target derivable from tcp://');
    is_deeply([$hv->virsh_argv('list')],
        ['virsh', '-c', 'qemu+tcp://hv2.example.net/system', 'list'],
        'virsh still works, it speaks the transport itself');
    eval { $hv->qx_hv('id -un') };
    like($@, qr/gives us no shell/, 'shell commands explain themselves');
    like($@, qr/hv_ssh_host/,       'and name the fix');
};

subtest 'explicit ssh overrides win' => sub {
    my $hv = Trog::HV->new(
        uri      => 'qemu+tcp://hv2.example.net/system',
        ssh_host => 'hv2.mgmt.example.net',
        ssh_user => 'ops',
        ssh_port => 2200,
    );
    is($hv->ssh_target, 'ops@hv2.mgmt.example.net', 'override host/user');
    is($hv->_wrap('id -un'),
        q{ssh -o BatchMode=yes -p 2200 ops@hv2.mgmt.example.net 'id -un'},
        'wrapped with the override');
    is($hv->uri, 'qemu+tcp://hv2.example.net/system', 'libvirt URI untouched');
};

# --- Quoting ------------------------------------------------------------------
subtest 'shell metacharacters survive the round trip' => sub {
    my $hv = Trog::HV->new(uri => 'qemu+ssh://hv/system');
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
    is(Trog::HV->new(uri => 'qemu:///system')->slug, 'qemu_system', 'local');
    is(Trog::HV->new(uri => 'qemu+ssh://root@hv1.example.net/system')->slug,
        'qemu_ssh_root_hv1_example_net_system', 'remote');
    unlike(Trog::HV->new(uri => 'qemu+ssh://root@hv1/system')->slug, qr{[^A-Za-z0-9_]},
        'no path separators');
};

# --- Local file operations degrade to plain filesystem calls ------------------
subtest 'local file helpers' => sub {
    my $hv  = Trog::HV->new();
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
    my $hv  = Trog::HV->new();
    my $dir = tempdir(CLEANUP => 1);
    my $ak  = "$dir/.ssh/authorized_keys";

    $hv->append_line_hv($ak, 'ssh-rsa AAAA one');
    $hv->append_line_hv($ak, 'ssh-rsa BBBB two');
    $hv->append_line_hv($ak, 'ssh-rsa AAAA one');

    my @lines = split(/\n/, read_text($ak));
    is(scalar(@lines), 2, 'the repeated key was only written once');
    is_deeply(\@lines, ['ssh-rsa AAAA one', 'ssh-rsa BBBB two'], 'in order');
};

subtest 'hv_user is us when the HV is us' => sub {
    my $hv = Trog::HV->new();
    is($hv->hv_user, scalar getpwuid($<), 'local transfer user is the caller');
};

# --- from_config --------------------------------------------------------------
subtest 'from_config reads provision.conf, CLI wins' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/provision.conf";
    write_text($file, join("\n",
        'libvirt_uri=qemu+tcp://confhv/system',
        'hv_ssh_host=confhv.mgmt',
        'hv_ssh_user=confuser',
        'hv_ssh_port=2202',
    ) . "\n");

    require Config::Simple;
    my $config = Config::Simple->new($file);

    my $from_conf = Trog::HV->from_config($config);
    is($from_conf->uri,        'qemu+tcp://confhv/system', 'uri from config');
    is($from_conf->ssh_target, 'confuser@confhv.mgmt',     'ssh host/user from config');
    is($from_conf->ssh_port,   2202,                       'ssh port from config');

    my $overridden = Trog::HV->from_config($config, uri => 'qemu+ssh://cli/system');
    is($overridden->uri, 'qemu+ssh://cli/system', 'CLI --connect beats config');

    my $no_config = Trog::HV->from_config(undef);
    ok($no_config->is_local, 'a missing config is just the local HV');
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

    my $hv  = Trog::HV->new(uri => 'qemu+ssh://root@fakehv/system');
    my $dir = tempdir(CLEANUP => 1);

    is($hv->qx_hv(q{echo 'one two' | tr a-z A-Z}), "ONE TWO\n",
        'a shell pipeline survives intact');

    is($hv->system_hv('test', '-d', $dir), 0, 'system_hv argv reaches the far side');
    isnt($hv->system_hv('test', '-d', "$dir/nope"), 0, 'and its exit code comes back');

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

    # Quoting hazards: spaces, single quotes, globs, and shell metacharacters
    # all have to arrive verbatim.
    my $nasty = "a b\tc 'quoted' \$HOME * ; rm -rf /";
    my $ak    = "$dir/keys/authorized_keys";
    $hv->append_line_hv($ak, $nasty);
    $hv->append_line_hv($ak, $nasty);
    is(read_text($ak), "$nasty\n", 'nasty line written once, verbatim');
};

done_testing;
