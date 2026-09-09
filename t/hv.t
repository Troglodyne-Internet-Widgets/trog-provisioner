#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/hv.t - Trog::HV: connection URIs, paths, libvirt and capacity

=cut

# A -f or -x in here is asserting on a file this test just made, in a temporary
# directory nothing else can see.  There is no window for it to be wrong in, so
# the TOCTOU policies have nothing to catch.
## no critic (ValuesAndExpressions::ProhibitFiletest_f, ValuesAndExpressions::ProhibitFiletest_rwxRWX)

use Test::More;
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use Test::MockModule qw{strict};
use Config::Simple();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }
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
    is( $hv->uri, 'qemu:///system', 'defaults to qemu:///system' );
    ok( $hv->is_local,  'is_local' );
    ok( !$hv->explicit, 'not explicit, so libvirt resolves its own default' );
    is( $hv->ssh_target, undef, 'no ssh target' );
    is( $hv->ssh,        undef, 'and nothing to connect to' );
};

subtest 'new() is a singleton' => sub {
    my $configured = fresh( uri => 'qemu+ssh://root@hv1.example.net/system' );
    is(
        Trog::HV->new()->uri, 'qemu+ssh://root@hv1.example.net/system',
        'a later new() with no arguments finds the hypervisor we configured'
    );
    is( Trog::HV->new(), $configured, 'and it is the very same object' );

    my $other = Trog::HV->new( uri => 'qemu+ssh://root@hv2.example.net/system' );
    isnt( $other, $configured, 'asking for a different URI builds a different one' );
    is(
        Trog::HV->new()->uri, 'qemu+ssh://root@hv2.example.net/system',
        'which becomes the one everything else sees'
    );
};

subtest 'explicitly asking for the local URI is still explicit' => sub {
    my $hv = fresh( uri => 'qemu:///system' );
    ok( $hv->is_local, 'still local' );
    ok( $hv->explicit, 'explicit' );
};

# --- URI parsing --------------------------------------------------------------
subtest 'qemu+ssh URI' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv1.example.net/system' );
    ok( !$hv->is_local, 'remote' );
    is( $hv->ssh_target, 'root@hv1.example.net', 'ssh target' );
    is( $hv->ssh_user,   'root',                 'ssh user' );
    is( $hv->ssh_port,   22,                     'port falls back to 22' );
};

subtest 'qemu+ssh URI with a port' => sub {
    my $hv = fresh( uri => 'qemu+ssh://admin@10.0.0.5:2222/system' );
    is( $hv->ssh_target, 'admin@10.0.0.5', 'ssh target' );
    is( $hv->ssh_port,   2222,             'port from URI' );
};

subtest 'bracketed IPv6 host' => sub {
    my $hv = fresh( uri => 'qemu+libssh2://[fe80::1]:22/system' );
    is( $hv->ssh_host, 'fe80::1', 'host unbracketed' );
    is( $hv->ssh_port, 22,        'port' );
};

subtest 'unparseable URI dies' => sub {
    Trog::HV->forget();
    eval { Trog::HV->new( uri => 'not a uri' ) };
    like( $@, qr/Could not parse libvirt connection URI/, 'dies loudly' );
};

# --- Transports that give us no shell ----------------------------------------
subtest 'a remote transport with no shell is refused up front' => sub {
    Trog::HV->forget();
    eval { Trog::HV->new( uri => 'qemu+tcp://hv2.example.net/system' ) };
    like( $@, qr/gives us no shell/,  'tcp:// is rejected rather than half-working' );
    like( $@, qr/qemu\+ssh:\/\/root/, 'and names the transport to use instead' );
};

# --- Slug ---------------------------------------------------------------------
subtest 'slug is filesystem safe and stable' => sub {
    is( fresh( uri => 'qemu:///system' )->slug, 'qemu_system', 'local' );
    is(
        fresh( uri => 'qemu+ssh://root@hv1.example.net/system' )->slug,
        'qemu_ssh_root_hv1_example_net_system', 'remote'
    );
    unlike(
        fresh( uri => 'qemu+ssh://root@hv1/system' )->slug, qr{[^A-Za-z0-9_]},
        'no path separators'
    );
};

# --- Paths --------------------------------------------------------------------
subtest 'pool and domain paths default the way they always did' => sub {
    my $hv = fresh();
    is( $hv->pool_path,  '/opt/terraform/disks', 'pool_path' );
    is( $hv->domain_dir, '/opt/domains',         'domain_dir' );

    my $set = fresh( uri => 'qemu+ssh://hv/system', pool_path => '/srv/pool', domain_dir => '/srv/domains' );
    is( $set->pool_path,  '/srv/pool',    'pool_path override' );
    is( $set->domain_dir, '/srv/domains', 'domain_dir override' );
};

subtest 'an existing pool says where it is, and is believed' => sub {
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( vmm => sub { FakePoolVMM->new('/var/lib/libvirt/images') } );

    is(
        fresh( uri => 'qemu+ssh://hv/system' )->pool_target('tf_disks'), '/var/lib/libvirt/images',
        'read straight out of the pool XML'
    );
    is(
        fresh( uri => 'qemu+ssh://hv/system' )->pool_path, '/var/lib/libvirt/images',
        'and used, rather than where we would have put one'
    );

    # An explicit setting still wins; it is the guess we are replacing.
    is(
        fresh( uri => 'qemu+ssh://hv/system', pool_path => '/srv/pool' )->pool_path, '/srv/pool',
        'pool_path from the config still wins'
    );

    # No pool yet, or no libvirt to ask: fall back rather than blow up.
    $mock->redefine( vmm => sub { die "no libvirt here\n" } );
    is( fresh( uri => 'qemu+ssh://hv/system' )->pool_target('tf_disks'), undef,                  'undef when we cannot ask' );
    is( fresh( uri => 'qemu+ssh://hv/system' )->pool_path,               '/opt/terraform/disks', 'and the default stands' );
};

{

    package FakePoolVMM;

    sub new                      { my ( $class, $path ) = @_; return bless { path => $path }, $class }
    sub get_storage_pool_by_name { return FakePool->new( $_[0]->{path} ) }
}

{

    package FakePool;

    sub new { my ( $class, $path ) = @_; return bless { path => $path }, $class }

    sub get_xml_description {
        my ($self) = @_;
        return qq{<pool type='dir'><name>tf_disks</name>} . qq{<target><path>$self->{path}</path><permissions><mode>0755</mode></permissions></target></pool>};
    }
}

# --- Which address we SSH to on the guest ------------------------------------
subtest 'guest_ssh_ip' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    File::Slurper::Temp::write_text( "$dir/with.conf", "ips=203.0.113.10\n" );
    my $conf_with = Config::Simple->new("$dir/with.conf");

    File::Slurper::Temp::write_text( "$dir/without.conf", "size=42949672960\n" );
    my $conf_without = Config::Simple->new("$dir/without.conf");

    my $local = fresh();
    is(
        $local->guest_ssh_ip( $conf_with, '192.168.122.50' ), '192.168.122.50',
        'a local hypervisor uses the NAT lease, as it always did'
    );
    is(
        $local->guest_ssh_ip( $conf_without, '192.168.122.50' ), '192.168.122.50',
        'even with no static IP configured'
    );

    my $remote = fresh( uri => 'qemu+ssh://hv1/system' );
    is(
        $remote->guest_ssh_ip( $conf_with, '192.168.122.50' ), '203.0.113.10',
        'a remote hypervisor uses the bridged static IP, which we can actually route to'
    );

    eval { $remote->guest_ssh_ip( $conf_without, '192.168.122.50' ) };
    like( $@, qr/requires the guest to have a/, 'and says so when there is none' );
    like( $@, qr/\bips\b/,                      'naming the config key to set' );
};

# --- The URI terraform gets is not always the one Sys::Virt gets -------------
# --- Local file operations degrade to plain filesystem calls ------------------
subtest 'local file helpers' => sub {
    my $hv  = fresh();
    my $dir = tempdir( CLEANUP => 1 );

    ok( !$hv->file_exists("$dir/nope"), 'file_exists false for missing' );
    ok( $hv->mkpath("$dir/a/b/c"),      'mkpath' );
    ok( -d "$dir/a/b/c",                'directory made' );

    $hv->write_text( "$dir/f", "hello\n" );
    ok( $hv->file_exists("$dir/f"), 'file_exists true after write' );
    is( $hv->read_text("$dir/f"), "hello\n", 'read_text' );

    $hv->remove("$dir/f");
    ok( !-f "$dir/f", 'remove' );

    is_deeply( [ sort $hv->list_dir($dir) ],     ['a'], 'list_dir names what is in a directory' );
    is_deeply( [ $hv->list_dir("$dir/nosuch") ], [],    'and says nothing about one that is not there' );

    $hv->remove_tree("$dir/a");
    ok( !-e "$dir/a", 'remove_tree takes the directory and what is under it' );
};

subtest 'append_line does not duplicate' => sub {
    my $hv  = fresh();
    my $dir = tempdir( CLEANUP => 1 );
    my $ak  = "$dir/.ssh/authorized_keys";

    $hv->append_line( $ak, 'ssh-rsa AAAA one' );
    $hv->append_line( $ak, 'ssh-rsa BBBB two' );
    $hv->append_line( $ak, 'ssh-rsa AAAA one' );

    my @lines = split( "\n", File::Slurper::read_text($ak) );
    is( scalar(@lines), 2, 'the repeated key was only written once' );
    is_deeply( \@lines, [ 'ssh-rsa AAAA one', 'ssh-rsa BBBB two' ], 'in order' );
};

# --- from_config --------------------------------------------------------------
subtest 'from_config reads provision.conf, the command line wins' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = "$dir/provision.conf";
    File::Slurper::Temp::write_text(
        $file,
        join(
            "\n", qw{
              libvirt_uri=qemu+ssh://confuser@confhv/system
              pool_path=/srv/pool
              domain_dir=/srv/domains
              bridge_device=br7
            }
          )
          . "\n"
    );

    my $config = Config::Simple->new($file);

    Trog::HV->forget();
    my $from_conf = Trog::HV->from_config($config);
    is( $from_conf->uri,           'qemu+ssh://confuser@confhv/system', 'uri from config' );
    is( $from_conf->ssh_target,    'confuser@confhv',                   'ssh host/user inferred from it' );
    is( $from_conf->pool_path,     '/srv/pool',                         'pool_path from config' );
    is( $from_conf->domain_dir,    '/srv/domains',                      'domain_dir from config' );
    is( $from_conf->bridge_device, 'br7',                               'bridge_device from config, no probing' );

    my $overridden = Trog::HV->from_config( $config, uri => 'qemu+ssh://cli/system' );
    is( $overridden->uri, 'qemu+ssh://cli/system', '--connect beats config' );

    Trog::HV->forget();
    ok( Trog::HV->from_config(undef)->is_local, 'a missing config is just the local hypervisor' );
};

# --- has_tpm ------------------------------------------------------------------
subtest 'a guest gets a TPM only where one means something' => sub {
    my ( $asked, $answer );
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( capture => sub { $asked = $_[1]; return $answer } );

    # Both halves: hardware here, and swtpm to emulate one there.  The command
    # says yes or says nothing, so anything that is not yes is no.
    foreach my $case ( [ "yes\n", 1, 'both halves' ], [ '', 0, 'neither' ], [ undef, 0, 'a command that said nothing at all' ] ) {
        my ( $said, $expected, $what ) = @$case;
        Trog::HV->forget();
        my $hv = Trog::HV->new();
        $answer = $said;
        is( $hv->has_tpm, $expected, "$what: has_tpm is $expected" );
    }

    like( $asked, qr{/dev/tpmrm0}, 'asks the hypervisor for its own TPM' );
    like( $asked, qr{swtpm},       'and for something to emulate one with' );

    # Asked once: this is a shell out to the hypervisor, per guest built.
    Trog::HV->forget();
    my $hv = Trog::HV->new();
    $answer = "yes\n";
    $hv->has_tpm;
    $answer = '';
    is( $hv->has_tpm, 1, 'and the answer is remembered rather than asked again' );
};

# --- Remote path, exercised against a mocked connection -----------------------
#
# Net::OpenSSH::More connects in its constructor, so there is no way to build a
# real one without a real hypervisor.  Mock it, and assert on what we ask it to
# do -- which since nothing goes through sftp any more is entirely commands and
# the streams we hand them.
subtest 'remote work goes through commands with an exit status' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@fakehv:2222/system' );

    my ( @connected, @commands, %files );

    # Stand in for the far side: `tee PATH` writes its stdin there, `cat PATH`
    # reads it back, `test -f` answers for it.
    my $run = sub {
        my ( $opts, @cmd ) = @_;
        push @commands, { opts => $opts, cmd => [@cmd] };

        my @argv = @cmd;
        shift @argv if $argv[0] eq 'sudo';

        if ( $argv[0] eq 'tee' ) {
            my $append = $argv[1] eq '-a';
            shift @argv if $append;

            my $content = $opts->{stdin_data};
            $content = do {
                open( my $fh, '<', $opts->{stdin_file} ) or return 0;
                local $/;
                <$fh>;
            } if defined $opts->{stdin_file};

            $append ? ( $files{ $argv[1] } .= $content ) : ( $files{ $argv[1] } = $content );
            return 1;
        }
        return exists $files{ $argv[2] } ? 1 : 0 if $argv[0] eq 'test';
        return 1;
    };

    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine(
        new => sub {
            my ( $class, %opts ) = @_;
            @connected = %opts;
            return bless {}, $class;
        }
    );
    $mock->redefine( system => sub { my ( $self, $opts, @cmd ) = @_; return $run->( $opts, @cmd ) } );

    # run_sudo goes through capture2, and this far side has passwordless sudo.
    $mock->redefine(
        capture2 => sub {
            my ( $self, $opts, @cmd ) = @_;
            push @commands, { opts => $opts, cmd => [@cmd] };

            my @argv = grep { $_ ne 'sudo' && $_ ne '-n' && $_ ne '-S' && $_ ne '-p' && length } @cmd;
            $files{ $argv[2] } = delete $files{ $argv[1] } if $argv[0] eq 'mv';

            $? = 0;
            return ( '', '' );
        }
    );
    $mock->redefine(
        capture => sub {
            my ( $self, $opts, @cmd ) = @_;
            push @commands, { opts => $opts, cmd => [@cmd] };
            return $files{ $cmd[1] };
        }
    );
    $mock->redefine( error => sub { 0 } );
    $mock->redefine(
        cmd => sub {
            my ( $self, @cmd ) = @_;
            push @commands, { cmd => [@cmd] };
            return ( '/tmp/staged.XXXX', '', 0 ) if "@cmd" eq 'mktemp';
            return ( "output of @cmd",   '', 0 );
        }
    );
    $mock->redefine(
        cmd_exit_code => sub {
            my ( $self, @cmd ) = @_;
            push @commands, { cmd => [@cmd] };
            my @argv = @cmd;
            shift @argv if $argv[0] eq 'sudo';

            return exists $files{ $argv[2] } ? 0 : 1 if $argv[0] eq 'test';
            if ( $argv[0] eq 'grep' ) {
                my ( $line, $file ) = @argv[ -2, -1 ];
                return 1 unless defined $files{$file};
                return ( grep { $_ eq $line } split( "\n", $files{$file} ) ) ? 0 : 1;
            }
            return 0;
        }
    );
    $mock->redefine( sftp => sub { die "nothing should be reaching sftp any more\n" } );

    # The connection is built from the URI, and only once.
    is( $hv->capture('id -un'), 'output of id -un', 'capture returns stdout' );
    my %opts = @connected;
    is( $opts{host}, 'fakehv', 'host from the URI' );
    is( $opts{user}, 'root',   'user from the URI' );
    is( $opts{port}, 2222,     'port from the URI' );
    ok( !$opts{use_persistent_shell}, 'the persistent shell is off, our commands are one-shot' );
    is( $hv->ssh, $hv->ssh, 'the connection is opened once and kept' );

    # Arguments go over as a list; Net::OpenSSH does the escaping we used to.
    my $nasty = "a b\tc 'quoted' \$HOME * ; rm -rf /";
    is( $hv->run( 'touch', $nasty ), 0, 'run returns the exit code' );
    is_deeply( $commands[-1]{cmd}, [ 'touch', $nasty ], 'unmangled, not pre-quoted' );

    # Content is poured down a command's stdin rather than put over sftp.
    $hv->write_text( '/tmp/plain', "hello\n" );
    is_deeply( $commands[-1]{cmd}, [ 'tee', '/tmp/plain' ], 'write_text tees it' );
    is( $commands[-1]{opts}{stdin_data}, "hello\n", 'with the content on stdin' );
    ok( $commands[-1]{opts}{timeout}, 'and a timeout, so a stall is an error' );
    is( $hv->read_text('/tmp/plain'), "hello\n", 'read_text cats it back' );
    ok( $hv->file_exists('/tmp/plain'), 'file_exists tests for it' );
    ok( !$hv->file_exists('/tmp/nope'), 'and is false for one that is not there' );

    # A privileged destination is staged and moved, because the content and the
    # sudo password both want stdin and cannot share it.
    ok( $hv->write_text( '/etc/rsyslog.d/10-vm.conf', "conf\n", sudo => 1 ), 'sudo write' );

    my ($tee) = grep { $_->{cmd}[0] eq 'tee' && $_->{cmd}[1] eq '/tmp/staged.XXXX' } @commands;
    ok( $tee, 'the content is teed unprivileged into a file we own' );
    is( $tee->{opts}{stdin_data}, "conf\n", 'with no password anywhere near it' );

    my $said = join '|', map { "@{$_->{cmd}}" } @commands;
    like( $said, qr{sudo -n mv /tmp/staged\.XXXX /etc/rsyslog\.d/10-vm\.conf}, 'then moved into place' );
    like( $said, qr{sudo -n chown root:root},                                  'chowned' );
    like( $said, qr{sudo -n chmod 0644},                                       'and chmodded, since tee would have used our umask' );
    is( $files{'/etc/rsyslog.d/10-vm.conf'}, "conf\n", 'and the bytes ended up there' );

    # put_file streams the local file down the same pipe.
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/src", "payload\n" );
    ok( $hv->put_file( "$dir/src", '/usr/libexec/thing', sudo => 1 ), 'put_file' );
    is( $files{'/usr/libexec/thing'}, "payload\n", 'the bytes arrived' );

    # append_line adds to what is there.  It used to pull the file across, add
    # a line and push the whole thing back, so a read that came back empty
    # rewrote somebody's authorized_keys with one key in it.
    my $ak = '/root/.ssh/authorized_keys';
    $files{$ak} = "ssh-rsa THEIRS somebody\n";

    $hv->append_line( $ak, 'ssh-rsa AAAA one' );
    $hv->append_line( $ak, 'ssh-rsa BBBB two' );
    $hv->append_line( $ak, 'ssh-rsa AAAA one' );

    is(
        $files{$ak}, "ssh-rsa THEIRS somebody\nssh-rsa AAAA one\nssh-rsa BBBB two\n",
        'the keys already there survive, and the repeat was written once'
    );
    ok( ( grep { "@{$_->{cmd}}" =~ m/\Atee -a / } @commands ), 'because it appends' );
    ok(
        !( grep { "@{$_->{cmd}}" eq "tee $ak" } @commands ),
        'and never rewrites the whole file, which is how you lock somebody out'
    );
};

# --- The backstop -------------------------------------------------------------
subtest 'a hang is an error with a name on it' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@fakehv/system' );

    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine( new    => sub { bless {}, shift } );
    $mock->redefine( system => sub { sleep 30; return 1 } );

    local $Trog::Machine::HANG_TIMEOUT = 1;

    my $started = time;
    eval { $hv->write_text( '/tmp/somewhere', "x\n" ) };
    my $took = time - $started;

    like( $@, qr/Gave up on the hypervisor/,          'we stop waiting' );
    like( $@, qr/qemu\+ssh:\/\/root\@fakehv\/system/, 'saying which one' );
    like( $@, qr/tee \/tmp\/somewhere/,               'and what we were doing' );
    like( $@, qr/permission\s+problem/,               'and what it usually means' );
    cmp_ok( $took, '<', 10, 'and we did it near the deadline, not after the sleep' );
};

# --- sudo that wants a password ----------------------------------------------
subtest 'a sudo password is asked for once and then remembered' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@needsauth/system' );

    my ( @attempts, $asked );
    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine( new => sub { bless {}, shift } );
    $mock->redefine(
        capture2 => sub {
            my ( $self, $opts, @cmd ) = @_;
            push @attempts, { cmd => [@cmd], stdin => $opts->{stdin_data} };

            # -n gets the message sudo gives when it cannot ask.
            if ( grep { $_ eq '-n' } @cmd ) {
                $? = 1 << 8;
                return ( '', "sudo: a password is required\n" );
            }
            $? = 0;
            return ( '', '' );
        }
    );

    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine( _ask_for_sudo_password => sub { $asked++; return $_[0]->_remember('hunter2') } );

    is( $hv->run_sudo(qw{systemctl restart rsyslog}), 0, 'the command succeeds in the end' );
    is( $asked,                                       1, 'we asked for a password' );

    is_deeply(
        $attempts[0]{cmd}, [qw{sudo -n systemctl restart rsyslog}],
        'the first go is -n, so a password requirement fails rather than waits on a terminal'
    );
    is( $attempts[0]{stdin}, undef, 'and sends nothing' );
    is_deeply(
        $attempts[1]{cmd}, [ qw{sudo -S -p}, q{}, qw{systemctl restart rsyslog} ],
        'the retry reads the password from stdin'
    );
    is( $attempts[1]{stdin}, "hunter2\n", 'which is where the password went' );

    # ...and not again, for anything else on the same machine.
    is( $hv->run_sudo(qw{systemctl restart cron}), 0,           'a later command also succeeds' );
    is( $asked,                                    1,           'without asking a second time' );
    is( $attempts[-1]{stdin},                      "hunter2\n", 'the remembered password was reused' );
};

subtest 'with no terminal to ask at, say what to configure' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@noterminal/system' );
    Trog::Machine::forget_sudo_passwords();

    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine( new      => sub { bless {}, shift } );
    $mock->redefine( capture2 => sub { $? = 1 << 8; return ( '', "sudo: a password is required\n" ) } );

    my $tty = Test::MockModule->new('Trog::Machine');
    $tty->redefine( _have_terminal => sub { 0 } );

    eval { $hv->run_sudo(qw{systemctl restart rsyslog}) };
    like( $@, qr/wants a password, and there is no terminal/, 'says what happened' );
    like( $@, qr/NOPASSWD/,                                   'and what to put in sudoers' );
    like( $@, qr/\broot\b/,                                   'for the right user' );
};

subtest 'the sudo password is asked for the same way every other one is' => sub {
    Trog::HV->forget();
    Trog::Machine->forget_sudo_passwords();
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $mock = Test::MockModule->new('Net::OpenSSH::More');
    $mock->redefine( new => sub { bless {}, shift } );
    $mock->redefine(
        capture2 => sub {
            my ( $self, $opts, @cmd ) = @_;

            # -n is the probe; it fails by design, which is what sends us to ask.
            if ( grep { $_ eq '-n' } @cmd ) {
                $? = 1 << 8;
                return ( '', "sudo: a password is required\n" );
            }
            $? = 0;
            return ( '', '' );
        }
    );

    my $tty = Test::MockModule->new('Trog::Machine');
    $tty->redefine( _have_terminal => sub { 1 } );

    # One way of asking, in Trog::Credentials, rather than a second one here
    # with Term::ReadKey doing its own echo suppression.
    my @asked;
    my $credentials = Test::MockModule->new('Trog::Credentials');
    $credentials->redefine( prompt => sub { push @asked, $_[1]; 'hunter2' } );

    quietly( sub { $hv->run_sudo(qw{true}) } );

    is( scalar @asked, 1, 'asked once' );
    like( $asked[0], qr/\[sudo\] password for root/, 'saying who it is for' );
    like( $asked[0], qr/hv/,                         'and which machine' );
};

# --- Building things, which is what terraform used to do ----------------------
subtest 'a disk is an overlay on the base image' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my @created;
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( volume_path => sub { undef } );
    $mock->redefine( pool        => sub { FakeBuildPool->new( \@created ) } );

    my $path = quietly(
        sub {
            $hv->create_disk(
                'vm.example.com-qcow2',
                backing => '/opt/terraform/disks/baseimage-qcow2', capacity => 42949672960
            );
        }
    );

    is( $path, '/opt/terraform/disks/vm.example.com-qcow2', 'made, and its path came back' );
    like( $created[0], qr{<name>vm\.example\.com-qcow2</name>}, 'named' );
    like( $created[0], qr{<capacity unit='bytes'>42949672960<}, 'sized' );
    like(
        $created[0], qr{<backingStore><path>/opt/terraform/disks/baseimage-qcow2</path>},
        'laid over the base image rather than copying it'
    );
    like( $created[0], qr{<format type='qcow2'/></backingStore>}, 'which is qcow2 too' );

    # One that is already there is left alone: it is a guest's filesystem.
    $mock->redefine( volume_path => sub { '/opt/terraform/disks/vm.example.com-qcow2' } );
    is(
        $hv->create_disk( 'vm.example.com-qcow2', backing => '/base', capacity => 1 ),
        '/opt/terraform/disks/vm.example.com-qcow2', 'an existing disk is returned, not remade'
    );
    is( scalar @created, 1, 'and nothing new was created' );
};

# --- What the hypervisor will actually take -----------------------------------
subtest 'a feature needs its libvirt, its qemu, and sometimes its qemu-img' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( libvirt_version  => sub { 10_000_000 } );                                 # 10.0.0
    $mock->redefine( qemu_version     => sub { 8_002_000 } );                                  # 8.2.0, which noble ships
    $mock->redefine( qemu_img_options => sub { +{ cluster_size => 1, extended_l2 => 1 } } );

    ok( $hv->supports('discard'),          'discard, on a libvirt long past 1.0.6' );
    ok( $hv->supports('discard_no_unref'), 'discard_no_unref, whose qemu 8.1 this qemu is past' );
    ok( $hv->supports('extended_l2'),      'extended_l2, which this qemu-img offers' );

    # The whole reason both halves are asked: libvirt 10 parses the mapping
    # quite happily and qemu 8.2 has no idea what to do with it, and the domain
    # defines and then will not start.
    ok( !$hv->supports('iothread_mapping'), 'but not queue mapping, which wants a qemu 9.0 this is not' );

    # A libvirt too old to pass the option along is a reason not to pay for the
    # probe at all, which is why the version is checked first.
    my $asked = 0;
    $mock->redefine( libvirt_version  => sub { 7_000_000 } );
    $mock->redefine( qemu_img_options => sub { $asked++; return {} } );
    $hv = fresh( uri => 'qemu+ssh://root@hv/system' );
    ok( !$hv->supports('extended_l2'), 'a libvirt older than 8.0 does not get extended_l2' );
    is( $asked, 0, 'and qemu-img was not asked, the answer being decided before the command' );
};

subtest 'an unanswerable hypervisor is assumed to support nothing' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( vmm => sub { die "no libvirt here\n" } );

    is( $hv->libvirt_version, 0, 'a connection that will not answer is a zero' );
    is( $hv->qemu_version,    0, 'for both of them' );
    ok( !$hv->supports('discard'), 'and nothing is emitted on the strength of it' );
};

subtest 'whether a pool takes O_DIRECT is asked of it, not inferred from its name' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my @ran;
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( run => sub { my ( $self, @argv ) = @_; push @ran, \@argv; return 0 } );

    ok( $hv->pool_takes_direct_io, 'a pool whose filesystem takes the write says so' );

    my $command = join( ' ', @{ $ran[0] } );
    like( $command, qr/oflag=direct/,                         'by doing the same O_DIRECT open qemu is about to do' );
    like( $command, qr/bs=4096/,                              'with a block a direct write can actually be aligned to' );
    like( $command, qr{/opt/terraform/disks/\.odirect-probe}, 'in the pool, which is the filesystem in question' );
    like( $command, qr/rm -f/,                                'and takes the probe file away again' );

    # Named filesystems are exactly what this stopped doing: tmpfs takes an
    # O_DIRECT write on a current kernel and ZFS has since 2.3, so a list of
    # names that supposedly cannot would today be wrong about both of them.
    $hv = fresh( uri => 'qemu+ssh://root@hv/system' );
    $mock->redefine( run => sub { return 1 } );
    ok( !$hv->pool_takes_direct_io, 'and one that refuses it says that instead' );

    $mock->redefine( run => sub { die "asked twice\n" } );
    ok( !$hv->pool_takes_direct_io, 'the answer is kept, a build asking once per disk' );
};

subtest 'how big a qcow2 has to be before its layout changes' => sub {
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( libvirt_version  => sub { 10_000_000 } );
    $mock->redefine( qemu_version     => sub { 9_000_000 } );
    $mock->redefine( qemu_img_options => sub { +{ cluster_size => 1, extended_l2 => 1 } } );

    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    # Subclusters are the point of the exercise: every guest disk is an overlay
    # on the shared base image, and without them a 4K write into a hole rewrites
    # a whole cluster out of the backing file.  Size has nothing to do with it.
    my %small = $hv->qcow2_tuning( 40 * 1024**3 );
    ok( $small{extended_l2}, 'a 40G overlay gets subcluster allocation' );
    is( $small{cluster_size},   undef, 'at the default cluster size' );
    is( $small{metadata_cache}, undef, 'and qemu is left to size its own metadata cache' );

    # 128 GiB is where the default 32 MiB of metadata cache stops covering the
    # whole image once extended L2 entries have doubled in width.
    my %edge = $hv->qcow2_tuning( 128 * 1024**3 );
    is( $edge{cluster_size}, undef, 'the last size the default cluster still covers is left alone' );

    my %large = $hv->qcow2_tuning( 200 * 1024**3 );
    is( $large{cluster_size},   1024 * 1024, 'past it, 1M clusters buy the coverage back' );
    is( $large{metadata_cache}, undef,       'which is enough on its own, so the cache is still qemu default' );

    # And past what even that covers, the cache is raised rather than the
    # clusters made coarser again.
    my %huge = $hv->qcow2_tuning( 8 * 1024**4 );
    is( $huge{cluster_size},   1024 * 1024,       '8T keeps the 1M clusters' );
    is( $huge{metadata_cache}, 128 * 1024 * 1024, 'and asks for the metadata cache it actually needs' );

    # Host memory, held for as long as the domain runs, and not counted by
    # anything in Trog::Hypervisors.  So there is a ceiling on it.
    my %vast = $hv->qcow2_tuning( 64 * 1024**4 );
    is( $vast{metadata_cache}, 256 * 1024 * 1024, 'up to a limit, past which it stops asking' );
};

subtest 'the disk is created with the tuning that was decided for it' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my @created;
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( volume_path  => sub { undef } );
    $mock->redefine( pool         => sub { FakeBuildPool->new( \@created ) } );
    $mock->redefine( qcow2_tuning => sub { ( extended_l2 => 1, cluster_size => 1048576 ) } );

    quietly( sub { $hv->create_disk( 'big-qcow2', backing => '/base', capacity => 200 * 1024**3 ) } );

    like( $created[0], qr{<clusterSize unit='bytes'>1048576</clusterSize>}, 'the cluster size reaches the volume' );
    like( $created[0], qr{<features><extended_l2/></features>},             'and so does subcluster allocation' );

    # Neither is retrofittable: both are properties of the image as created, so
    # a disk that already exists stays exactly as it is.  It is a filesystem.
    $mock->redefine( volume_path => sub { '/opt/terraform/disks/big-qcow2' } );
    is(
        $hv->create_disk( 'big-qcow2', backing => '/base', capacity => 200 * 1024**3 ),
        '/opt/terraform/disks/big-qcow2', 'an existing disk is not remade to suit a new opinion'
    );
    is( scalar @created, 1, 'and nothing new was created' );
};

subtest 'the cloud-init seed is an ISO labelled cidata' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my ( @ran, %written );
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( mkpath       => sub { 1 } );
    $mock->redefine( write_text   => sub { $written{ $_[1] } = $_[2]; return 1 } );
    $mock->redefine( refresh_pool => sub { 1 } );
    $mock->redefine( iso_maker    => sub { 'xorriso' } );
    $mock->redefine( run          => sub { my ( $s, @c ) = @_; push @ran, [@c]; return 0 } );

    my $path = quietly(
        sub {
            $hv->cloudinit_iso(
                'vm.example.com',
                'user-data'      => "#cloud-config\n",
                'meta-data'      => "instance-id: vm\n",
                'network-config' => "version: 1\n"
            );
        }
    );

    is( $path, '/opt/terraform/disks/vm.example.com-cloudinit.iso', 'lands in the pool' );

    my ($iso) = grep { $_->[0] eq 'xorriso' } @ran;
    is_deeply( [ @{$iso}[ 0, 1, 2 ] ], [qw{xorriso -as mkisofs}], 'xorriso in mkisofs mode' );
    ok( ( grep { $_ eq 'cidata' } @$iso ), 'labelled cidata, which is how NoCloud finds it' );
    ok( ( grep { m/user-data\z/ } @$iso ), 'with the user-data' );

    is( scalar( grep { m{/user-data\z} } keys %written ), 1, 'the files were written out first' );
    ok( ( grep { $_->[0] eq 'rm' } @ran ), 'and the workdir cleaned up after' );
};

subtest 'the base image is fetched once' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my @ran;
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( volume_path  => sub { undef } );
    $mock->redefine( refresh_pool => sub { 1 } );
    $mock->redefine( run          => sub { my ( $s, @c ) = @_; push @ran, join( ' ', @c ); return 0 } );

    quietly( sub { $hv->base_image('https://example.test/noble.img') } );

    ok(
        ( grep { m/curl .*\.partial/ } @ran ),
        'downloaded to a partial name, so libvirt never sees a half a file'
    );
    ok( ( grep { m/\Amv .*\.partial / } @ran ), 'and moved into place after' );

    # Already there: no fetch at all.
    @ran = ();
    $mock->redefine( volume_path => sub { '/opt/terraform/disks/baseimage-qcow2' } );
    is(
        $hv->base_image('https://example.test/noble.img'), '/opt/terraform/disks/baseimage-qcow2',
        'an image already in the pool is used as it is'
    );
    is_deeply( \@ran, [], 'nothing was fetched' );

    # No image and no URL is an error, not an empty download.
    $mock->redefine( volume_path => sub { undef } );
    eval { $hv->base_image(undef) };
    like( $@, qr/No image URL configured/, 'and nothing to fetch is an error' );
};

{

    package FakeBuildPool;

    sub new { my ( $class, $created ) = @_; return bless { created => $created }, $class }

    sub create_volume {
        my ( $self, $xml ) = @_;
        push @{ $self->{created} }, $xml;
        my ($name) = $xml =~ m{<name>([^<]+)</name>};
        return FakeBuildVolume->new("/opt/terraform/disks/$name");
    }
}

{

    package FakeBuildVolume;

    sub new      { my ( $class, $path ) = @_; return bless { path => $path }, $class }
    sub get_path { return $_[0]->{path} }
}

sub quietly {
    my ($code) = @_;
    open( my $capture, '>', \my $out ) or die $!;
    my @result = do { local *STDOUT = $capture; $code->() };
    close $capture;
    return wantarray ? @result : $result[0];
}

# --- Guest identity, which is what makes device names knowable ---------------
subtest 'a guest MAC is derived from its name and does not move' => sub {
    my $hv = fresh();

    my $nat    = $hv->guest_mac( 'vm.example.com', 0 );
    my $bridge = $hv->guest_mac( 'vm.example.com', 1 );

    like( $nat, qr/\A52:54:00(:[0-9a-f]{2}){3}\z/, 'a QEMU-prefixed MAC' );
    isnt( $nat, $bridge, 'the two interfaces differ' );

    is(
        $hv->guest_mac( 'vm.example.com', 0 ), $nat,
        'the same guest gets the same MAC every time, so its lease survives a rebuild'
    );
    isnt( $hv->guest_mac( 'other.example.com', 0 ), $nat, 'a different guest does not' );

    # Any hypervisor agrees, since it comes from the name and nothing else.
    is(
        fresh( uri => 'qemu+ssh://hv2/system' )->guest_mac( 'vm.example.com', 0 ), $nat,
        'and so does another hypervisor'
    );

    is_deeply( [ $hv->nic_slots ], [ 3, 4 ], 'the slots are pinned, which is what makes ens3/ens4 true' );
};

subtest 'leases are looked up by MAC, not by name' => sub {
    my $hv = fresh( uri => 'qemu+ssh://hv/system' );

    my @asked;
    my $mock = Test::MockModule->new('Trog::HV');
    $mock->redefine( vmm => sub { FakeLeaseVMM->new( \@asked ) } );

    is( $hv->lease_ip( 'default', mac => '52:54:00:aa:bb:cc' ), '192.168.122.50',    'found' );
    is( $asked[0],                                              '52:54:00:aa:bb:cc', 'and dnsmasq was asked about that MAC, not sifted afterwards' );

    # The hostname match is still there, and is still a substring match: a guest
    # called vm.example.com matches a lease for sub.vm.example.com.
    is( $hv->lease_ip( 'default', hostname => 'vm.example.com' ), '192.168.122.50', 'hostname still works' );
    is( $hv->lease_ip( 'default', hostname => 'nothing.here' ),   undef,            'and misses when it should' );
};

{

    package FakeLeaseVMM;

    sub new                 { my ( $class, $asked ) = @_; return bless { asked => $asked }, $class }
    sub get_network_by_name { return FakeNet->new( $_[0]->{asked} ) }
}

{

    package FakeNet;

    sub new { my ( $class, $asked ) = @_; return bless { asked => $asked }, $class }

    sub get_dhcp_leases {
        my ( $self, $mac ) = @_;
        push @{ $self->{asked} }, $mac;
        return ( { ipaddr => '192.168.122.50', mac => '52:54:00:aa:bb:cc', hostname => 'vm.example.com' } );
    }
}

subtest 'a command that names its own timeout is not called hung before it' => sub {

    # _unhang exists to notice a command that should return promptly and does
    # not.  wait_for_makefile's is `sudo timeout 180m bash -c 'until atq is
    # empty ...'`, which is meant to block for as long as the guest takes to
    # build -- and the ten minute alarm killed it regardless, so every setup
    # timeout above ten minutes was decorative and a guest still compiling came
    # back as a failure.  Only the remote path reaches _unhang, which is why
    # this never appeared against a local hypervisor.
    is(
        Trog::Machine::_hang_limit('virsh list --all'), $Trog::Machine::HANG_TIMEOUT,
        'an ordinary command gets the default'
    );

    is(
        Trog::Machine::_hang_limit("sudo timeout 180m bash -c 'until :; do :; done'"),
        180 * 60 + 60, 'one that says 180m gets 180m and a minute'
    );

    is(
        Trog::Machine::_hang_limit('sudo timeout 90 something'), $Trog::Machine::HANG_TIMEOUT,
        'and one shorter than the default does not lower it'
    );

    is( Trog::Machine::_hang_limit(undef), $Trog::Machine::HANG_TIMEOUT, 'undef is the default' );
};

done_testing;
