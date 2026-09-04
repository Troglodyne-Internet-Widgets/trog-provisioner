#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper qw{read_text write_text};
use Test::MockModule qw{strict};
use Config::Simple();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }
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
subtest 'pool and domain paths default the way they always did' => sub {
    my $hv = fresh();
    is($hv->pool_path,  '/opt/terraform/disks', 'pool_path');
    is($hv->domain_dir, '/opt/domains',         'domain_dir');

    my $set = fresh(uri => 'qemu+ssh://hv/system', pool_path => '/srv/pool', domain_dir => '/srv/domains');
    is($set->pool_path,  '/srv/pool',    'pool_path override');
    is($set->domain_dir, '/srv/domains', 'domain_dir override');
};

subtest 'an existing pool says where it is, and is believed' => sub {
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(vmm => sub { FakePoolVMM->new('/var/lib/libvirt/images') });

    is(fresh(uri => 'qemu+ssh://hv/system')->pool_target('tf_disks'), '/var/lib/libvirt/images',
        'read straight out of the pool XML');
    is(fresh(uri => 'qemu+ssh://hv/system')->pool_path, '/var/lib/libvirt/images',
        'and used, rather than where we would have put one');

    # An explicit setting still wins; it is the guess we are replacing.
    is(fresh(uri => 'qemu+ssh://hv/system', pool_path => '/srv/pool')->pool_path, '/srv/pool',
        'pool_path from the config still wins');

    # No pool yet, or no libvirt to ask: fall back rather than blow up.
    $mock->redefine(vmm => sub { die "no libvirt here\n" });
    is(fresh(uri => 'qemu+ssh://hv/system')->pool_target('tf_disks'), undef, 'undef when we cannot ask');
    is(fresh(uri => 'qemu+ssh://hv/system')->pool_path, '/opt/terraform/disks', 'and the default stands');
};

{
    package FakePoolVMM;

    sub new { my ($class, $path) = @_; return bless { path => $path }, $class }
    sub get_storage_pool_by_name { return FakePool->new($_[0]->{path}) }
}

{
    package FakePool;

    sub new { my ($class, $path) = @_; return bless { path => $path }, $class }

    sub get_xml_description {
        my ($self) = @_;
        return qq{<pool type='dir'><name>tf_disks</name>}
          . qq{<target><path>$self->{path}</path><permissions><mode>0755</mode></permissions></target></pool>};
    }
}

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

# --- The URI terraform gets is not always the one Sys::Virt gets -------------
# --- Local file operations degrade to plain filesystem calls ------------------
subtest 'local file helpers' => sub {
    my $hv  = fresh();
    my $dir = tempdir(CLEANUP => 1);

    ok(!$hv->file_exists("$dir/nope"), 'file_exists false for missing');
    ok($hv->mkpath("$dir/a/b/c"),      'mkpath');
    ok(-d "$dir/a/b/c",                   'directory made');

    $hv->write_text("$dir/f", "hello\n");
    ok($hv->file_exists("$dir/f"), 'file_exists true after write');
    is($hv->read_text("$dir/f"), "hello\n", 'read_text');

    $hv->remove("$dir/f");
    ok(!-f "$dir/f", 'remove');
};

subtest 'append_line does not duplicate' => sub {
    my $hv  = fresh();
    my $dir = tempdir(CLEANUP => 1);
    my $ak  = "$dir/.ssh/authorized_keys";

    $hv->append_line($ak, 'ssh-rsa AAAA one');
    $hv->append_line($ak, 'ssh-rsa BBBB two');
    $hv->append_line($ak, 'ssh-rsa AAAA one');

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
            my $append = $argv[1] eq '-a';
            shift @argv if $append;

            my $content = $opts->{stdin_data};
            $content = do {
                open(my $fh, '<', $opts->{stdin_file}) or return 0;
                local $/;
                <$fh>;
            } if defined $opts->{stdin_file};

            $append ? ($files{ $argv[1] } .= $content) : ($files{ $argv[1] } = $content);
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

    # run_sudo goes through capture2, and this far side has passwordless sudo.
    $mock->redefine(capture2 => sub {
        my ($self, $opts, @cmd) = @_;
        push @commands, { opts => $opts, cmd => [@cmd] };

        my @argv = grep { $_ ne 'sudo' && $_ ne '-n' && $_ ne '-S' && $_ ne '-p' && length } @cmd;
        $files{ $argv[2] } = delete $files{ $argv[1] } if $argv[0] eq 'mv';

        $? = 0;
        return ('', '');
    });
    $mock->redefine(capture => sub {
        my ($self, $opts, @cmd) = @_;
        push @commands, { opts => $opts, cmd => [@cmd] };
        return $files{ $cmd[1] };
    });
    $mock->redefine(error => sub { 0 });
    $mock->redefine(cmd => sub {
        my ($self, @cmd) = @_;
        push @commands, { cmd => [@cmd] };
        return ('/tmp/staged.XXXX', '', 0) if "@cmd" eq 'mktemp';
        return ("output of @cmd", '', 0);
    });
    $mock->redefine(cmd_exit_code => sub {
        my ($self, @cmd) = @_;
        push @commands, { cmd => [@cmd] };
        my @argv = @cmd;
        shift @argv if $argv[0] eq 'sudo';

        return exists $files{ $argv[2] } ? 0 : 1 if $argv[0] eq 'test';
        if ($argv[0] eq 'grep') {
            my ($line, $file) = @argv[-2, -1];
            return 1 unless defined $files{$file};
            return (grep { $_ eq $line } split(/\n/, $files{$file})) ? 0 : 1;
        }
        return 0;
    });
    $mock->redefine(sftp => sub { die "nothing should be reaching sftp any more\n" });

    # The connection is built from the URI, and only once.
    is($hv->capture('id -un'), 'output of id -un', 'capture returns stdout');
    my %opts = @connected;
    is($opts{host}, 'fakehv', 'host from the URI');
    is($opts{user}, 'root',   'user from the URI');
    is($opts{port}, 2222,     'port from the URI');
    ok(!$opts{use_persistent_shell}, 'the persistent shell is off, our commands are one-shot');
    is($hv->ssh, $hv->ssh, 'the connection is opened once and kept');

    # Arguments go over as a list; Net::OpenSSH does the escaping we used to.
    my $nasty = "a b\tc 'quoted' \$HOME * ; rm -rf /";
    is($hv->run('touch', $nasty), 0, 'run returns the exit code');
    is_deeply($commands[-1]{cmd}, ['touch', $nasty], 'unmangled, not pre-quoted');

    # Content is poured down a command's stdin rather than put over sftp.
    $hv->write_text('/tmp/plain', "hello\n");
    is_deeply($commands[-1]{cmd}, ['tee', '/tmp/plain'], 'write_text tees it');
    is($commands[-1]{opts}{stdin_data}, "hello\n", 'with the content on stdin');
    ok($commands[-1]{opts}{timeout}, 'and a timeout, so a stall is an error');
    is($hv->read_text('/tmp/plain'), "hello\n", 'read_text cats it back');
    ok($hv->file_exists('/tmp/plain'), 'file_exists tests for it');
    ok(!$hv->file_exists('/tmp/nope'), 'and is false for one that is not there');

    # A privileged destination is staged and moved, because the content and the
    # sudo password both want stdin and cannot share it.
    ok($hv->write_text('/etc/rsyslog.d/10-vm.conf', "conf\n", sudo => 1), 'sudo write');

    my ($tee) = grep { $_->{cmd}[0] eq 'tee' && $_->{cmd}[1] eq '/tmp/staged.XXXX' } @commands;
    ok($tee, 'the content is teed unprivileged into a file we own');
    is($tee->{opts}{stdin_data}, "conf\n", 'with no password anywhere near it');

    my $said = join '|', map { "@{$_->{cmd}}" } @commands;
    like($said, qr{sudo -n mv /tmp/staged\.XXXX /etc/rsyslog\.d/10-vm\.conf}, 'then moved into place');
    like($said, qr{sudo -n chown root:root},  'chowned');
    like($said, qr{sudo -n chmod 0644},       'and chmodded, since tee would have used our umask');
    is($files{'/etc/rsyslog.d/10-vm.conf'}, "conf\n", 'and the bytes ended up there');

    # put_file streams the local file down the same pipe.
    my $dir = tempdir(CLEANUP => 1);
    write_text("$dir/src", "payload\n");
    ok($hv->put_file("$dir/src", '/usr/libexec/thing', sudo => 1), 'put_file');
    is($files{'/usr/libexec/thing'}, "payload\n", 'the bytes arrived');

    # append_line adds to what is there.  It used to pull the file across, add
    # a line and push the whole thing back, so a read that came back empty
    # rewrote somebody's authorized_keys with one key in it.
    my $ak = '/root/.ssh/authorized_keys';
    $files{$ak} = "ssh-rsa THEIRS somebody\n";

    $hv->append_line($ak, 'ssh-rsa AAAA one');
    $hv->append_line($ak, 'ssh-rsa BBBB two');
    $hv->append_line($ak, 'ssh-rsa AAAA one');

    is($files{$ak}, "ssh-rsa THEIRS somebody\nssh-rsa AAAA one\nssh-rsa BBBB two\n",
        'the keys already there survive, and the repeat was written once');
    ok((grep { "@{$_->{cmd}}" =~ m/\Atee -a / } @commands), 'because it appends');
    ok(!(grep { "@{$_->{cmd}}" eq "tee $ak" } @commands),
        'and never rewrites the whole file, which is how you lock somebody out');
};

# --- The backstop -------------------------------------------------------------
subtest 'a hang is an error with a name on it' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@fakehv/system');

    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine(new    => sub { bless {}, shift });
    $mock->redefine(system => sub { sleep 30; return 1 });

    local $Trog::Machine::HANG_TIMEOUT = 1;

    my $started = time;
    eval { $hv->write_text('/tmp/somewhere', "x\n") };
    my $took = time - $started;

    like($@, qr/Gave up on the hypervisor/, 'we stop waiting');
    like($@, qr/qemu\+ssh:\/\/root\@fakehv\/system/, 'saying which one');
    like($@, qr/tee \/tmp\/somewhere/, 'and what we were doing');
    like($@, qr/permission\s+problem/, 'and what it usually means');
    cmp_ok($took, '<', 10, 'and we did it near the deadline, not after the sleep');
};

# --- sudo that wants a password ----------------------------------------------
subtest 'a sudo password is asked for once and then remembered' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@needsauth/system');

    my (@attempts, $asked);
    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine(new => sub { bless {}, shift });
    $mock->redefine(capture2 => sub {
        my ($self, $opts, @cmd) = @_;
        push @attempts, { cmd => [@cmd], stdin => $opts->{stdin_data} };

        # -n gets the message sudo gives when it cannot ask.
        if (grep { $_ eq '-n' } @cmd) {
            $? = 1 << 8;
            return ('', "sudo: a password is required\n");
        }
        $? = 0;
        return ('', '');
    });

    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine(_ask_for_sudo_password => sub { $asked++; return $_[0]->_remember('hunter2') });

    is($hv->run_sudo(qw{systemctl restart rsyslog}), 0, 'the command succeeds in the end');
    is($asked, 1, 'we asked for a password');

    is_deeply($attempts[0]{cmd}, [qw{sudo -n systemctl restart rsyslog}],
        'the first go is -n, so a password requirement fails rather than waits on a terminal');
    is($attempts[0]{stdin}, undef, 'and sends nothing');
    is_deeply($attempts[1]{cmd}, [qw{sudo -S -p}, q{}, qw{systemctl restart rsyslog}],
        'the retry reads the password from stdin');
    is($attempts[1]{stdin}, "hunter2\n", 'which is where the password went');

    # ...and not again, for anything else on the same machine.
    is($hv->run_sudo(qw{systemctl restart cron}), 0, 'a later command also succeeds');
    is($asked, 1, 'without asking a second time');
    is($attempts[-1]{stdin}, "hunter2\n", 'the remembered password was reused');
};

subtest 'with no terminal to ask at, say what to configure' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@noterminal/system');
    Trog::Machine::forget_sudo_passwords();

    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine(new => sub { bless {}, shift });
    $mock->redefine(capture2 => sub { $? = 1 << 8; return ('', "sudo: a password is required\n") });

    my $tty = Test::MockModule->new('Trog::Machine');
    $tty->redefine(_have_terminal => sub { 0 });

    eval { $hv->run_sudo(qw{systemctl restart rsyslog}) };
    like($@, qr/wants a password, and there is no terminal/, 'says what happened');
    like($@, qr/NOPASSWD/,                                   'and what to put in sudoers');
    like($@, qr/\broot\b/,                                   'for the right user');
};

# --- Building things, which is what terraform used to do ----------------------
subtest 'a disk is an overlay on the base image' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@hv/system');

    my @created;
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(volume_path => sub { undef });
    $mock->redefine(pool        => sub { FakeBuildPool->new(\@created) });

    my $path = quietly(sub { $hv->create_disk('vm.example.com-qcow2',
        backing => '/opt/terraform/disks/baseimage-qcow2', capacity => 42949672960) });

    is($path, '/opt/terraform/disks/vm.example.com-qcow2', 'made, and its path came back');
    like($created[0], qr{<name>vm\.example\.com-qcow2</name>},  'named');
    like($created[0], qr{<capacity unit='bytes'>42949672960<},   'sized');
    like($created[0], qr{<backingStore><path>/opt/terraform/disks/baseimage-qcow2</path>},
        'laid over the base image rather than copying it');
    like($created[0], qr{<format type='qcow2'/></backingStore>}, 'which is qcow2 too');

    # One that is already there is left alone: it is a guest's filesystem.
    $mock->redefine(volume_path => sub { '/opt/terraform/disks/vm.example.com-qcow2' });
    is($hv->create_disk('vm.example.com-qcow2', backing => '/base', capacity => 1),
        '/opt/terraform/disks/vm.example.com-qcow2', 'an existing disk is returned, not remade');
    is(scalar @created, 1, 'and nothing new was created');
};

subtest 'the cloud-init seed is an ISO labelled cidata' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@hv/system');

    my (@ran, %written);
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(mkpath       => sub { 1 });
    $mock->redefine(write_text   => sub { $written{ $_[1] } = $_[2]; return 1 });
    $mock->redefine(refresh_pool => sub { 1 });
    $mock->redefine(iso_maker    => sub { 'xorriso' });
    $mock->redefine(run          => sub { my ($s, @c) = @_; push @ran, [@c]; return 0 });

    my $path = quietly(sub {
        $hv->cloudinit_iso('vm.example.com',
            'user-data'      => "#cloud-config\n",
            'meta-data'      => "instance-id: vm\n",
            'network-config' => "version: 1\n");
    });

    is($path, '/opt/terraform/disks/vm.example.com-cloudinit.iso', 'lands in the pool');

    my ($iso) = grep { $_->[0] eq 'xorriso' } @ran;
    is_deeply([@{$iso}[0, 1, 2]], [qw{xorriso -as mkisofs}], 'xorriso in mkisofs mode');
    ok((grep { $_ eq 'cidata' } @$iso), 'labelled cidata, which is how NoCloud finds it');
    ok((grep { m/user-data\z/ } @$iso), 'with the user-data');

    is(scalar(grep { m{/user-data\z} } keys %written), 1, 'the files were written out first');
    ok((grep { $_->[0] eq 'rm' } @ran), 'and the workdir cleaned up after');
};

subtest 'the base image is fetched once' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@hv/system');

    my @ran;
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(volume_path  => sub { undef });
    $mock->redefine(refresh_pool => sub { 1 });
    $mock->redefine(run          => sub { my ($s, @c) = @_; push @ran, join(' ', @c); return 0 });

    quietly(sub { $hv->base_image('https://example.test/noble.img') });

    ok((grep { m/curl .*\.partial/ } @ran),
        'downloaded to a partial name, so libvirt never sees a half a file');
    ok((grep { m/\Amv .*\.partial /  } @ran), 'and moved into place after');

    # Already there: no fetch at all.
    @ran = ();
    $mock->redefine(volume_path => sub { '/opt/terraform/disks/baseimage-qcow2' });
    is($hv->base_image('https://example.test/noble.img'), '/opt/terraform/disks/baseimage-qcow2',
        'an image already in the pool is used as it is');
    is_deeply(\@ran, [], 'nothing was fetched');

    # No image and no URL is an error, not an empty download.
    $mock->redefine(volume_path => sub { undef });
    eval { $hv->base_image(undef) };
    like($@, qr/No image URL configured/, 'and nothing to fetch is an error');
};

{
    package FakeBuildPool;

    sub new { my ($class, $created) = @_; return bless { created => $created }, $class }

    sub create_volume {
        my ($self, $xml) = @_;
        push @{ $self->{created} }, $xml;
        my ($name) = $xml =~ m{<name>([^<]+)</name>};
        return FakeBuildVolume->new("/opt/terraform/disks/$name");
    }
}

{
    package FakeBuildVolume;

    sub new      { my ($class, $path) = @_; return bless { path => $path }, $class }
    sub get_path { return $_[0]->{path} }
}

sub quietly {
    my ($code) = @_;
    open(my $capture, '>', \my $out) or die $!;
    my @result = do { local *STDOUT = $capture; $code->() };
    close $capture;
    return wantarray ? @result : $result[0];
}

# --- Guest identity, which is what makes device names knowable ---------------
subtest 'a guest MAC is derived from its name and does not move' => sub {
    my $hv = fresh();

    my $nat    = $hv->guest_mac('vm.example.com', 0);
    my $bridge = $hv->guest_mac('vm.example.com', 1);

    like($nat, qr/\A52:54:00(:[0-9a-f]{2}){3}\z/, 'a QEMU-prefixed MAC');
    isnt($nat, $bridge, 'the two interfaces differ');

    is($hv->guest_mac('vm.example.com', 0), $nat,
        'the same guest gets the same MAC every time, so its lease survives a rebuild');
    isnt($hv->guest_mac('other.example.com', 0), $nat, 'a different guest does not');

    # Any hypervisor agrees, since it comes from the name and nothing else.
    is(fresh(uri => 'qemu+ssh://hv2/system')->guest_mac('vm.example.com', 0), $nat,
        'and so does another hypervisor');

    is_deeply([$hv->nic_slots], [3, 4], 'the slots are pinned, which is what makes ens3/ens4 true');
};

subtest 'leases are looked up by MAC, not by name' => sub {
    my $hv = fresh(uri => 'qemu+ssh://hv/system');

    my @asked;
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine(vmm => sub { FakeLeaseVMM->new(\@asked) });

    is($hv->lease_ip('default', mac => '52:54:00:aa:bb:cc'), '192.168.122.50', 'found');
    is($asked[0], '52:54:00:aa:bb:cc', 'and dnsmasq was asked about that MAC, not sifted afterwards');

    # The hostname match is still there, and is still a substring match: a guest
    # called vm.example.com matches a lease for sub.vm.example.com.
    is($hv->lease_ip('default', hostname => 'vm.example.com'), '192.168.122.50', 'hostname still works');
    is($hv->lease_ip('default', hostname => 'nothing.here'), undef, 'and misses when it should');
};

{
    package FakeLeaseVMM;

    sub new { my ($class, $asked) = @_; return bless { asked => $asked }, $class }
    sub get_network_by_name { return FakeNet->new($_[0]->{asked}) }
}

{
    package FakeNet;

    sub new { my ($class, $asked) = @_; return bless { asked => $asked }, $class }

    sub get_dhcp_leases {
        my ($self, $mac) = @_;
        push @{ $self->{asked} }, $mac;
        return ({ ipaddr => '192.168.122.50', mac => '52:54:00:aa:bb:cc', hostname => 'vm.example.com' });
    }
}

done_testing;
