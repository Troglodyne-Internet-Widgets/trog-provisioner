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
# do: that is the whole of our side of the contract now that it does the
# quoting and the transfers.
subtest 'remote work goes through Net::OpenSSH::More' => sub {
    my $hv = fresh(uri => 'qemu+ssh://root@fakehv:2222/system');

    my (@connected, @commands);
    my $fake_sftp = FakeSFTP->new();

    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine(new => sub {
        my ($class, %opts) = @_;
        @connected = %opts;
        return bless {}, $class;
    });
    $mock->redefine(cmd => sub {
        my ($self, @cmd) = @_;
        push @commands, [@cmd];
        return ("output of @cmd", '', 0);
    });
    $mock->redefine(cmd_exit_code => sub {
        my ($self, @cmd) = @_;
        push @commands, [@cmd];
        return 0;
    });
    $mock->redefine(sftp => sub { $fake_sftp });

    # The connection is built from the URI, and only once.
    is($hv->qx_hv('id -un'), 'output of id -un', 'qx_hv returns stdout');
    my %opts = @connected;
    is($opts{host}, 'fakehv', 'host from the URI');
    is($opts{user}, 'root',   'user from the URI');
    is($opts{port}, 2222,     'port from the URI');
    ok(!$opts{use_persistent_shell}, 'the persistent shell is off, our commands are one-shot');

    my $conn = $hv->ssh;
    is($hv->ssh, $conn, 'the connection is opened once and kept');

    # A pipeline goes over as one string; an argv list goes over as a list, and
    # Net::OpenSSH does the escaping we used to do by hand.
    $hv->qx_hv(q{brctl show | grep -v virbr});
    is_deeply($commands[-1], [q{brctl show | grep -v virbr}], 'a pipeline is passed through whole');

    my $nasty = "a b\tc 'quoted' \$HOME * ; rm -rf /";
    is($hv->system_hv('touch', $nasty), 0, 'system_hv returns the exit code');
    is_deeply($commands[-1], ['touch', $nasty], 'arguments are handed over unmangled, not pre-quoted');

    # Files go over sftp on that same connection.
    $hv->write_text_hv('/tmp/plain', "hello\n");
    is($fake_sftp->{content}{'/tmp/plain'}, "hello\n",
        'write_text_hv puts a real file rather than going through put_content');
    ok($hv->file_exists_hv('/tmp/plain'), 'file_exists_hv sees it');
    is($hv->read_text_hv('/tmp/plain'), "hello\n",
        'read_text_hv gets a real file rather than going through get_content');
    is($hv->read_text_hv('/tmp/missing'), undef, 'and undef for one that is not there');

    ok(!$hv->file_exists_hv('/tmp/nope'), 'file_exists_hv false for missing');

    # A root-owned destination stages, then moves with sudo.
    ok($hv->write_text_hv('/etc/rsyslog.d/10-vm.conf', "conf\n", sudo => 1), 'sudo write');
    my ($mv) = grep { $_->[0] eq 'sudo' && $_->[1] eq 'mv' } @commands;
    ok($mv, 'the staged file is moved into place with sudo');
    is($mv->[3], '/etc/rsyslog.d/10-vm.conf', 'to the right destination');
    ok((grep { $_->[0] eq 'sudo' && $_->[1] eq 'chown' } @commands),
        'and chowned, since mv keeps the staging user');

    # The whole domain directory goes, not just the tarball.
    ok($hv->put_dir('/opt/domains/vm', '/opt/domains/vm'), 'put_dir');
    is_deeply($fake_sftp->{rput}[-1], ['/opt/domains/vm', '/opt/domains/vm'], 'recursively');

    # append_line_hv reads what is there and does not duplicate.
    $hv->append_line_hv('/root/.ssh/authorized_keys', 'ssh-rsa AAAA one');
    $hv->append_line_hv('/root/.ssh/authorized_keys', 'ssh-rsa BBBB two');
    $hv->append_line_hv('/root/.ssh/authorized_keys', 'ssh-rsa AAAA one');
    is($fake_sftp->{content}{'/root/.ssh/authorized_keys'},
        "ssh-rsa AAAA one\nssh-rsa BBBB two\n", 'the repeated key was only written once');
};

# A stand-in for Net::SFTP::Foreign holding files in a hash.
{
    package FakeSFTP;
    use strict;
    use warnings FATAL => 'all';

    sub new { return bless { content => {}, rput => [] }, shift }

    sub stat {
        my ($self, $path) = @_;
        return undef unless exists $self->{content}{$path};
        return FakeSFTP::Attrs->new();
    }

    sub get_content { return $_[0]->{content}{ $_[1] } }

    sub get {
        my ( $self, $remote, $local ) = @_;
        return 0 unless exists $self->{content}{$remote};
        open( my $fh, '>', $local ) or return 0;
        print {$fh} $self->{content}{$remote};
        close $fh;
        return 1;
    }
    sub put_content { $_[0]->{content}{ $_[2] } = $_[1]; return 1 }

    # A real put reads the local file, and so does this: storing a placeholder
    # would let a write_text_hv that sends the wrong bytes pass.
    sub put {
        my ( $self, $local, $remote ) = @_;
        open( my $fh, '<', $local ) or return 0;
        $self->{content}{$remote} = do { local $/; <$fh> };
        close $fh;
        return 1;
    }
    sub mkpath      { return 1 }
    sub rput        { my ($s, @a) = @_; push @{ $s->{rput} }, [@a]; return 1 }
}

{
    package FakeSFTP::Attrs;
    use strict;
    use warnings FATAL => 'all';
    use Fcntl();

    sub new  { return bless {}, shift }
    sub perm { return Fcntl::S_IFREG() | 0644 }
}

done_testing;
