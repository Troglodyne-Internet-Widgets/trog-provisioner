#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

use warnings FATAL => 'all';

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper qw{read_text write_text};
use Test::MockModule qw{strict};
use Config::Simple();

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
    is($hv->ssh_target, undef, 'no ssh target');
    is($hv->ssh,        undef, 'and nothing to connect to');
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
    is($hv->ssh_port,   22,                     'port falls back to 22');
};

subtest 'qemu+ssh URI with a port' => sub {
    my $hv = fresh(uri => 'qemu+ssh://admin@10.0.0.5:2222/system');
    is($hv->ssh_target, 'admin@10.0.0.5', 'ssh target');
    is($hv->ssh_port,   2222,             'port from URI');
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

# --- Remote path, exercised against a mocked connection -----------------------
#
# Net::OpenSSH::More connects in its constructor, so there is no way to build a
# real one without a real hypervisor.  Mock it, and assert on what we ask it to
# do -- which since nothing goes through sftp any more is entirely commands and
# the streams we hand them.
subtest 'remote work goes through commands with an exit status' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@fakehv:2222/system');

    my (@connected, @commands, %files);

    # Stand in for the far side: `tee PATH` writes its stdin there, `cat PATH`
    # reads it back, `test -f` answers for it.
    my $run = sub {
        my ($opts, @cmd) = @_;
        push @commands, { opts => $opts, cmd => [@cmd] };

        my @argv = @cmd;
        shift @argv if $argv[0] eq 'sudo';

        if ($argv[0] eq 'tee') {
            my $content = $opts->{stdin_data};
            $content = do {
                open(my $fh, '<', $opts->{stdin_file}) or return 0;
                local $/;
                <$fh>;
            } if defined $opts->{stdin_file};
            $files{ $argv[1] } = $content;
            return 1;
        }
        return exists $files{ $argv[2] } ? 1 : 0 if $argv[0] eq 'test';
        return 1;
    };

    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine(new => sub {
        my ($class, %opts) = @_;
        @connected = %opts;
        return bless {}, $class;
    });
    $mock->redefine(system => sub { my ($self, $opts, @cmd) = @_; return $run->($opts, @cmd) });
    $mock->redefine(capture => sub {
        my ($self, $opts, @cmd) = @_;
        push @commands, { opts => $opts, cmd => [@cmd] };
        return $files{ $cmd[1] };
    });
    $mock->redefine(error => sub { 0 });
    $mock->redefine(cmd => sub {
        my ($self, @cmd) = @_;
        push @commands, { cmd => [@cmd] };
        return ("output of @cmd", '', 0);
    });
    $mock->redefine(cmd_exit_code => sub {
        my ($self, @cmd) = @_;
        push @commands, { cmd => [@cmd] };
        my @argv = @cmd;
        shift @argv if $argv[0] eq 'sudo';
        return $argv[0] eq 'test' ? (exists $files{ $argv[2] } ? 0 : 1) : 0;
    });
    $mock->redefine(sftp => sub { die "nothing should be reaching sftp any more\n" });

    # The connection is built from the URI, and only once.
    is($hv->qx_hv('id -un'), 'output of id -un', 'qx_hv returns stdout');
    my %opts = @connected;
    is($opts{host}, 'fakehv', 'host from the URI');
    is($opts{user}, 'root',   'user from the URI');
    is($opts{port}, 2222,     'port from the URI');
    ok(!$opts{use_persistent_shell}, 'the persistent shell is off, our commands are one-shot');
    is($hv->ssh, $hv->ssh, 'the connection is opened once and kept');

    # Arguments go over as a list; Net::OpenSSH does the escaping we used to.
    my $nasty = "a b\tc 'quoted' \$HOME * ; rm -rf /";
    is($hv->system_hv('touch', $nasty), 0, 'system_hv returns the exit code');
    is_deeply($commands[-1]{cmd}, ['touch', $nasty], 'unmangled, not pre-quoted');

    # Content is poured down a command's stdin rather than put over sftp.
    $hv->write_text_hv('/tmp/plain', "hello\n");
    is_deeply($commands[-1]{cmd}, ['tee', '/tmp/plain'], 'write_text_hv tees it');
    is($commands[-1]{opts}{stdin_data}, "hello\n", 'with the content on stdin');
    ok($commands[-1]{opts}{timeout}, 'and a timeout, so a stall is an error');
    is($hv->read_text_hv('/tmp/plain'), "hello\n", 'read_text_hv cats it back');
    ok($hv->file_exists_hv('/tmp/plain'), 'file_exists_hv tests for it');
    ok(!$hv->file_exists_hv('/tmp/nope'), 'and is false for one that is not there');

    # A root-owned destination is written by sudo directly, with no staging
    # file in between to get the permissions of wrong.
    ok($hv->write_text_hv('/etc/rsyslog.d/10-vm.conf', "conf\n", sudo => 1), 'sudo write');
    my ($tee) = grep { $_->{cmd}[0] eq 'sudo' && $_->{cmd}[1] eq 'tee' } @commands;
    is_deeply($tee->{cmd}, [qw{sudo tee /etc/rsyslog.d/10-vm.conf}], 'sudo tee, straight to the destination');
    ok((grep { "@{$_->{cmd}}" eq 'sudo chmod 0644 /etc/rsyslog.d/10-vm.conf' } @commands),
        'and a chmod, since tee would have used our umask');
    ok(!(grep { "@{$_->{cmd}}" =~ m/^sudo mv/ } @commands), 'nothing was staged anywhere first');

    # put_file streams the local file down the same pipe.
    my $dir = tempdir(CLEANUP => 1);
    write_text("$dir/src", "payload\n");
    ok($hv->put_file("$dir/src", '/usr/libexec/thing', sudo => 1), 'put_file');
    is($files{'/usr/libexec/thing'}, "payload\n", 'the bytes arrived');

    # append_line_hv reads what is there and does not duplicate.
    $hv->append_line_hv('/root/.ssh/authorized_keys', 'ssh-rsa AAAA one');
    $hv->append_line_hv('/root/.ssh/authorized_keys', 'ssh-rsa BBBB two');
    $hv->append_line_hv('/root/.ssh/authorized_keys', 'ssh-rsa AAAA one');
    is($files{'/root/.ssh/authorized_keys'}, "ssh-rsa AAAA one\nssh-rsa BBBB two\n",
        'the repeated key was only written once');
};

# --- The backstop -------------------------------------------------------------
subtest 'a hang is an error with a name on it' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@fakehv/system');

    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine(new    => sub { bless {}, shift });
    $mock->redefine(system => sub { sleep 30; return 1 });

    local $Trog::HV::HANG_TIMEOUT = 1;

    my $started = time;
    eval { $hv->write_text_hv('/etc/somewhere', "x\n", sudo => 1) };
    my $took = time - $started;

    like($@, qr/Gave up on the hypervisor/, 'we stop waiting');
    like($@, qr/qemu\+ssh:\/\/root\@fakehv\/system/, 'saying which one');
    like($@, qr/sudo tee \/etc\/somewhere/, 'and what we were doing');
    like($@, qr/permission\s+problem/, 'and what it usually means');
    cmp_ok($took, '<', 10, 'and we did it near the deadline, not after the sleep');
};

done_testing;
