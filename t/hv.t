#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/hv.t - Trog::HV: connection URIs, paths, libvirt and capacity

=cut

# A -f or -x in here is asserting on a file this test just made, in a temporary
# directory nothing else can see.  There is no window for it to be wrong in, so
# the TOCTOU policies have nothing to catch.
## no critic (ValuesAndExpressions::ProhibitFiletest_f, ValuesAndExpressions::ProhibitFiletest_rwxRWX)

use Test::More;
use Test::Fatal   qw{exception};
use Capture::Tiny qw{capture_stdout};
use File::Temp    qw{tempdir};
use List::Util    qw{any};
use File::Slurper();
use File::Slurper::Temp();
use Test::MockModule qw{strict};
use Config::Simple();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo
use Trog::HV();

# Loaded so Test::MockModule has a package to attach to: Trog::HV requires its
# backend lazily, and it is named only as a string below.
use Trog::HV::Libvirt();    ## no critic (ProhibitUnusedImports)

# Every subtest wants a hypervisor of its own, and new() hands back the last one
# it built unless you ask for something different.
sub fresh (@args) {
    Trog::HV->forget();
    return Trog::HV->new(@args);
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
    my $configured = fresh( uri => 'qemu+ssh://root@hv1.example.test/system' );
    is(
        Trog::HV->new()->uri, 'qemu+ssh://root@hv1.example.test/system',
        'a later new() with no arguments finds the hypervisor we configured'
    );
    is( Trog::HV->new(), $configured, 'and it is the very same object' );

    my $other = Trog::HV->new( uri => 'qemu+ssh://root@hv2.example.test/system' );
    isnt( $other, $configured, 'asking for a different URI builds a different one' );
    is(
        Trog::HV->new()->uri, 'qemu+ssh://root@hv2.example.test/system',
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
    my $hv = fresh( uri => 'qemu+ssh://root@hv1.example.test/system' );
    ok( !$hv->is_local, 'remote' );
    is( $hv->ssh_target, 'root@hv1.example.test', 'ssh target' );
    is( $hv->ssh_user,   'root',                  'ssh user' );
    is( $hv->ssh_port,   22,                      'port falls back to 22' );
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
    like( exception { Trog::HV->new( uri => 'not a uri' ) }, qr/Could[ ]not[ ]parse[ ]libvirt[ ]connection[ ]URI/, 'dies loudly' );
};

# --- Transports that give us no shell ----------------------------------------
subtest 'a remote transport with no shell is refused up front' => sub {
    Trog::HV->forget();
    my $err = exception { Trog::HV->new( uri => 'qemu+tcp://hv2.example.test/system' ) };
    like( $err, qr/gives[ ]us[ ]no[ ]shell/, 'tcp:// is rejected rather than half-working' );
    like( $err, qr/qemu\+ssh:\/\/root/,      'and names the transport to use instead' );
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

subtest 'a backend that leaves something out is told what' => sub {
    my @owed = qw{
      build config_keys capacity
      domain_exists annihilate_domain guest_names guest_ssh_ip
      snapshot_names snapshot_current_name create_snapshot revert_snapshot
      prepare_host release_seed guest_volumes
    };

    {

        package Trog::HV::HalfDone;
        use parent -norequire, 'Trog::HV';
    }
    my $half = bless {}, 'Trog::HV::HalfDone';

    # In words, at the call, rather than "Can't locate object method" from
    # somewhere up in bin/provision.
    foreach my $method (@owed) {
        my $err = exception { $half->$method('vm.test') };
        ok( $err, "$method dies" );
        like( $err, qr/\ATrog::HV::HalfDone[ ]does[ ]not[ ]implement[ ]\Q$method\E,[ ]which[ ]every[ ]backend[ ]has[ ]to$/, 'naming the backend and what it owes' );    ## no critic (RegularExpressions::ProhibitComplexRegexes)
    }

    # And the two there are owe nothing.
    foreach my $backend ( Trog::HV->backends ) {
        my @missing = grep { $backend->can($_) == Trog::HV->can($_) } @owed;
        is_deeply( \@missing, [], "$backend implements every one of them" );
    }
};

subtest 'a hypervisor can be given a pool and a slice of its own' => sub {

    # Both default to what every hypervisor built by the old tool has, so a
    # fleet that says nothing behaves exactly as it did.
    my $hv = fresh();
    is( $hv->pool_name, 'tf_disks', 'the pool everything has always used' );
    is( $hv->partition, undef,      'and no partition, which libvirt reads as /machine' );

    # Named because pool_path alone cannot do it: libvirt looks a pool up by
    # name, so a path given beside the name of a pool that already exists
    # somewhere else is ignored and every volume lands in the existing one --
    # silently, which is somebody believing in a quota that is not there.
    my $own = fresh(
        uri       => 'qemu+ssh://hv/system',
        pool_path => '/pool/vm-disks/runner',
        pool_name => 'runner_disks',
        partition => '/machine/runner',
    );
    is( $own->pool_name, 'runner_disks',          'the pool it was given' );
    is( $own->pool_path, '/pool/vm-disks/runner', 'at the path it was given' );
    is( $own->partition, '/machine/runner',       'and the slice its guests are placed in' );
};

subtest 'an existing pool says where it is, and is believed' => sub {
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
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

    sub new                                   { my ( $class, $path ) = @_; return bless { path => $path }, $class }
    sub get_storage_pool_by_name ( $self, $ ) { return FakePool->new( $self->{path} ) }
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

    my $err = exception { $remote->guest_ssh_ip( $conf_without, '192.168.122.50' ) };
    like( $err, qr/requires[ ]the[ ]guest[ ]to[ ]have[ ]a/, 'and says so when there is none' );
    like( $err, qr/\bips\b/,                                'naming the config key to set' );
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

    my @lines = split( m/\n/, File::Slurper::read_text($ak) );
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
              pool_name=runner_disks
              partition=/machine/runner
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
    is( $from_conf->pool_name,     'runner_disks',                      'pool_name from config' );
    is( $from_conf->partition,     '/machine/runner',                   'partition from config' );

    my $overridden = Trog::HV->from_config( $config, uri => 'qemu+ssh://cli/system' );
    is( $overridden->uri, 'qemu+ssh://cli/system', '--connect beats config' );

    Trog::HV->forget();
    ok( Trog::HV->from_config(undef)->is_local, 'a missing config is just the local hypervisor' );
};

# --- has_tpm ------------------------------------------------------------------
subtest 'a guest gets a TPM only where one means something' => sub {
    my ( $asked, $answer );
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( capture_cmd => sub { $asked = $_[1]; return $answer } );

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
                my $slurped = <$fh>;
                close($fh) or die "Could not close $opts->{stdin_file}: $!";
                $slurped;
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

            $? = 0;    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the caller reads it afterwards, as it would from the real call
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
                return ( grep { $_ eq $line } split( m/\n/, $files{$file} ) ) ? 0 : 1;
            }
            return 0;
        }
    );
    $mock->redefine( sftp => sub { die "nothing should be reaching sftp any more\n" } );

    # The connection is built from the URI, and only once.
    is( $hv->capture_cmd('id -un'), 'output of id -un', 'capture returns stdout' );
    my %opts = @connected;
    is( $opts{host}, 'fakehv', 'host from the URI' );
    is( $opts{user}, 'root',   'user from the URI' );
    is( $opts{port}, 2222,     'port from the URI' );
    ok( !$opts{use_persistent_shell}, 'the persistent shell is off, our commands are one-shot' );
    is( $hv->ssh, $hv->ssh, 'the connection is opened once and kept' );

    # Arguments go over as a list; Net::OpenSSH does the escaping we used to.
    my $nasty = "a b\tc 'quoted' \$HOME * ; rm -rf /";
    is( $hv->run_cmd( 'touch', $nasty ), 0, 'run returns the exit code' );
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
    like( $said, qr{sudo[ ]-n[ ]mv[ ]/tmp/staged\.XXXX[ ]/etc/rsyslog\.d/10-vm\.conf}, 'then moved into place' );                               ## no critic (RegularExpressions::ProhibitComplexRegexes)
    like( $said, qr{sudo[ ]-n[ ]chown[ ]root:root},                                    'chowned' );
    like( $said, qr{sudo[ ]-n[ ]chmod[ ]0644},                                         'and chmodded, since tee would have used our umask' );
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
    ok( ( grep { "@{$_->{cmd}}" =~ m/\Atee[ ]-a[ ]/ } @commands ), 'because it appends' );
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
    my $err     = exception { $hv->write_text( '/tmp/somewhere', "x\n" ) };
    my $took    = time - $started;

    like( $err, qr/Gave[ ]up[ ]on[ ]the[ ]hypervisor/,  'we stop waiting' );
    like( $err, qr/qemu\+ssh:\/\/root\@fakehv\/system/, 'saying which one' );
    like( $err, qr/tee[ ]\/tmp\/somewhere/,             'and what we were doing' );
    like( $err, qr/permission\s+problem/,               'and what it usually means' );
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
            if ( any { $_ eq '-n' } @cmd ) {
                $? = 1 << 8;    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the caller reads it afterwards, as it would from the real call
                return ( '', "sudo: a password is required\n" );
            }
            $? = 0;             ## no critic (Variables::RequireLocalizedPunctuationVars) -- the caller reads it afterwards, as it would from the real call
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
    $mock->redefine( capture2 => sub { $? = 1 << 8; return ( '', "sudo: a password is required\n" ) } );    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the caller reads it afterwards, as it would from the real call

    local $Trog::Credentials::TERMINAL = '/bogus/tty';

    my $err = exception { $hv->run_sudo(qw{systemctl restart rsyslog}) };
    like( $err, qr/wants[ ]a[ ]password,[ ]and[ ]it[ ]could[ ]not[ ]be[ ]asked[ ]for/, 'says what happened' );           ## no critic (RegularExpressions::ProhibitComplexRegexes)
    like( $err, qr{Cannot[ ]ask[ ]for[ ]sudo[ ]at[ ]a[ ]terminal:[ ]/bogus/tty},       'and why it could not ask' );
    like( $err, qr/NOPASSWD/,                                                          'and what to put in sudoers' );
    like( $err, qr/\broot\b/,                                                          'for the right user' );
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
            if ( any { $_ eq '-n' } @cmd ) {
                $? = 1 << 8;    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the caller reads it afterwards, as it would from the real call
                return ( '', "sudo: a password is required\n" );
            }
            $? = 0;             ## no critic (Variables::RequireLocalizedPunctuationVars) -- the caller reads it afterwards, as it would from the real call
            return ( '', '' );
        }
    );

    # One way of asking, in Trog::Credentials, rather than a second one here
    # with Term::ReadKey doing its own echo suppression.
    my @asked;
    my $credentials = Test::MockModule->new('Trog::Credentials');
    $credentials->redefine( prompt => sub { push @asked, $_[1]; 'hunter2' } );

    quietly( sub { $hv->run_sudo(qw{true}) } );

    is( scalar @asked, 1, 'asked once' );
    like( $asked[0], qr/\[sudo\][ ]password[ ]for[ ]root/, 'saying who it is for' );
    like( $asked[0], qr/hv/,                               'and which machine' );
};

# --- Building things, which is what terraform used to do ----------------------
subtest 'a disk is an overlay on the base image' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my @created;
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( volume_path => sub { undef } );
    $mock->redefine( pool        => sub { FakeBuildPool->new( \@created ) } );

    my $path = quietly(
        sub {
            $hv->create_disk(
                'vm.example.test-qcow2',
                backing => '/opt/terraform/disks/baseimage-qcow2', capacity => 42949672960
            );
        }
    );

    is( $path, '/opt/terraform/disks/vm.example.test-qcow2', 'made, and its path came back' );
    like( $created[0], qr{<name>vm\.example\.test-qcow2</name>},  'named' );
    like( $created[0], qr{<capacity[ ]unit='bytes'>42949672960<}, 'sized' );
    like(
        $created[0], qr{<backingStore><path>/opt/terraform/disks/baseimage-qcow2</path>},    ## no critic (RegularExpressions::ProhibitComplexRegexes)
        'laid over the base image rather than copying it'
    );
    like( $created[0], qr{<format[ ]type='qcow2'/></backingStore>}, 'which is qcow2 too' );

    # One that is already there is left alone: it is a guest's filesystem.
    $mock->redefine( volume_path => sub { '/opt/terraform/disks/vm.example.test-qcow2' } );
    is(
        $hv->create_disk( 'vm.example.test-qcow2', backing => '/base', capacity => 1 ),
        '/opt/terraform/disks/vm.example.test-qcow2', 'an existing disk is returned, not remade'
    );
    is( scalar @created, 1, 'and nothing new was created' );
};

# --- What the hypervisor will actually take -----------------------------------
subtest 'a feature needs its libvirt, its qemu, and sometimes its qemu-img' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
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

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( vmm => sub { die "no libvirt here\n" } );

    is( $hv->libvirt_version, 0, 'a connection that will not answer is a zero' );
    is( $hv->qemu_version,    0, 'for both of them' );
    ok( !$hv->supports('discard'), 'and nothing is emitted on the strength of it' );
};

subtest 'whether a pool takes O_DIRECT is asked of it, not inferred from its name' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my @ran;
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( run_cmd => sub { my ( $self, @argv ) = @_; push @ran, \@argv; return 0 } );

    ok( $hv->pool_takes_direct_io, 'a pool whose filesystem takes the write says so' );

    my $command = join( ' ', @{ $ran[0] } );
    like( $command, qr/oflag=direct/,                         'by doing the same O_DIRECT open qemu is about to do' );
    like( $command, qr/bs=4096/,                              'with a block a direct write can actually be aligned to' );
    like( $command, qr{/opt/terraform/disks/\.odirect-probe}, 'in the pool, which is the filesystem in question' );
    like( $command, qr/rm[ ]-f/,                              'and takes the probe file away again' );

    # Named filesystems are exactly what this stopped doing: tmpfs takes an
    # O_DIRECT write on a current kernel and ZFS has since 2.3, so a list of
    # names that supposedly cannot would today be wrong about both of them.
    $hv = fresh( uri => 'qemu+ssh://root@hv/system' );
    $mock->redefine( run_cmd => sub { return 1 } );
    ok( !$hv->pool_takes_direct_io, 'and one that refuses it says that instead' );

    $mock->redefine( run_cmd => sub { die "asked twice\n" } );
    ok( !$hv->pool_takes_direct_io, 'the answer is kept, a build asking once per disk' );
};

subtest 'how big a qcow2 has to be before its layout changes' => sub {
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
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
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( volume_path  => sub { undef } );
    $mock->redefine( pool         => sub { FakeBuildPool->new( \@created ) } );
    $mock->redefine( qcow2_tuning => sub { ( extended_l2 => 1, cluster_size => 1048576 ) } );

    quietly( sub { $hv->create_disk( 'big-qcow2', backing => '/base', capacity => 200 * 1024**3 ) } );

    like( $created[0], qr{<clusterSize[ ]unit='bytes'>1048576</clusterSize>}, 'the cluster size reaches the volume' );
    like( $created[0], qr{<features><extended_l2/></features>},               'and so does subcluster allocation' );

    # Neither is retrofittable: both are properties of the image as created, so
    # a disk that already exists stays exactly as it is.  It is a filesystem.
    $mock->redefine( volume_path => sub { '/opt/terraform/disks/big-qcow2' } );
    is(
        $hv->create_disk( 'big-qcow2', backing => '/base', capacity => 200 * 1024**3 ),
        '/opt/terraform/disks/big-qcow2', 'an existing disk is not remade to suit a new opinion'
    );
    is( scalar @created, 1, 'and nothing new was created' );
};

# --- Keeping a guest's disk across a rebuild ----------------------------------

{

    package FakeVolume;

    sub new { my ( $class, %info ) = @_; return bless {%info}, $class }
    sub get_info { my ($self) = @_; return { capacity => $self->{capacity} } }
}

{

    package FakeStoppableDomain;

    sub new             { my ( $class, $active, $stopped ) = @_; return bless { active => $active, stopped => $stopped }, $class }
    sub is_active       { my ($self) = @_; return $self->{active} }
    sub destroy         { my ($self) = @_; ${ $self->{stopped} }++; return 1 }
    sub get_uuid_string { return '35341952-6f2b-457a-a882-80f6c47e2d2c' }
}

subtest 'what a disk was made with is read off the disk rather than remembered' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $asked;
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( volume_path => sub { '/opt/terraform/disks/vm.test-qcow2' } );
    $mock->redefine( capture_cmd => sub { $asked = $_[1]; return '{"cluster-size":65536,"format-specific":{"data":{"extended-l2":true}}}' } );

    $hv->disk_layout('vm.test-qcow2');

    # The command, not just the answer.  Both of these shipped broken because
    # the mock returned a good answer to a question that could not be asked: the
    # disk is 0600 libvirt-qemu:kvm, and the guest holding it open means qemu-img
    # cannot open it without -U.  Either way the sub returned empty, which reads
    # as "no snapshots" and switches the whole feature off.
    like( $asked, qr/\b sudo \b/, 'asked as root, the disk not being ours' );
    like( $asked, qr/-U\b/,       'and forcing a share, the guest having it open' );
    unlike( $asked, qr{2 > /dev/null}, 'with the errors left where they can be seen' );

    is_deeply(
        $hv->disk_layout('vm.test-qcow2'),
        { cluster_size => 65536, extended_l2 => 1 },
        'the cluster size it was made with, and whether it has subclusters'
    );

    # Undef rather than a guess, because disk_reusable reads a guess as
    # "reusable" -- and keeping a disk laid out the wrong way pins the guest to
    # that layout for as long as it lives.
    $mock->redefine( capture_cmd => sub { 'qemu-img: command not found' } );
    is( $hv->disk_layout('vm.test-qcow2'), undef, 'anything that is not JSON is undef' );

    $mock->redefine( volume_path => sub { undef } );
    is( $hv->disk_layout('vm.test-qcow2'), undef, 'and so is a volume that is not there' );
};

subtest 'the snapshots in a disk are read out of the table qemu-img prints' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    # As qemu-img 8.2 prints it, header and all.
    my $listing = <<'LIST';
Snapshot list:
ID        TAG               VM SIZE                DATE     VM CLOCK     ICOUNT
1         trog-pristine         0 B 2026-09-17 00:44:03 00:00:00.000          0
2         before-reprovision-17    0 B 2026-09-17 00:45:01 00:00:00.000          0
LIST

    my $asked;
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( volume_path => sub { '/opt/terraform/disks/vm.test-qcow2' } );
    $mock->redefine( capture_cmd => sub { $asked = $_[1]; return $listing } );

    is_deeply(
        [ $hv->disk_snapshot_names('vm.test-qcow2') ],
        [qw{trog-pristine before-reprovision-17}],
        'the tags, and not the header sitting above them'
    );

    $mock->redefine( capture_cmd => sub { q{} } );
    is_deeply( [ $hv->disk_snapshot_names('vm.test-qcow2') ], [], 'a disk with none says none' );
};

subtest 'a disk can be kept only when it is the disk that would be made now' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( volume       => sub { FakeVolume->new( capacity => 42949672960 ) } );
    $mock->redefine( qcow2_tuning => sub { ( extended_l2  => 1 ) } );
    $mock->redefine( disk_layout  => sub { { cluster_size => 65536, extended_l2 => 1 } } );

    ok $hv->disk_reusable( 'vm.test',  42949672960 ), 'the same size, laid out the same way';
    ok !$hv->disk_reusable( 'vm.test', 85899345920 ), 'a different size is a different disk';

    # Neither of these can be retrofitted onto an image that exists, so a
    # hypervisor that would lay one out differently now cannot keep this one.
    $mock->redefine( disk_layout => sub { { cluster_size => 1048576, extended_l2 => 1 } } );
    ok !$hv->disk_reusable( 'vm.test', 42949672960 ), 'and neither is a different cluster size';

    $mock->redefine( disk_layout => sub { { cluster_size => 65536, extended_l2 => 0 } } );
    ok !$hv->disk_reusable( 'vm.test', 42949672960 ), 'nor subcluster allocation it does not have';

    $mock->redefine( disk_layout => sub { { cluster_size => 65536, extended_l2 => 1 } } );
    $mock->redefine( volume      => sub { undef } );
    ok !$hv->disk_reusable( 'vm.test', 42949672960 ), 'and a guest with no disk yet has none to keep';
};

subtest 'a rollback needs a disk that can be kept and something to put it back to' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists       => sub { 1 } );
    $mock->redefine( disk_reusable       => sub { 1 } );
    $mock->redefine( disk_snapshot_names => sub { return qw{trog-pristine} } );

    ok $hv->rollback_possible( 'vm.test', capacity => 42949672960 ), 'a disk that can be kept, with a pristine snapshot in it';

    # The case that would otherwise fail in the middle of the rebuild, after the
    # rollback point had been taken and announced: a guest built before any of
    # this has a perfectly reusable disk and nothing in it to revert to.
    $mock->redefine( disk_snapshot_names => sub { return qw{before-reprovision-17} } );
    ok !$hv->rollback_possible( 'vm.test', capacity => 42949672960 ), 'a disk with no pristine snapshot cannot be put back';

    $mock->redefine( disk_snapshot_names => sub { return qw{trog-pristine} } );
    $mock->redefine( disk_reusable       => sub { 0 } );
    ok !$hv->rollback_possible( 'vm.test', capacity => 42949672960 ), 'nor can a disk that is about to be deleted';

    $mock->redefine( disk_reusable => sub { 1 } );
    $mock->redefine( domain_exists => sub { 0 } );
    ok !$hv->rollback_possible( 'vm.test', capacity => 42949672960 ), 'and a first build has nothing to go back to';
};

subtest 'stopping a domain leaves it defined' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $stopped = 0;
    my $mock    = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( _domain => sub { FakeStoppableDomain->new( 1, \$stopped ) } );

    ok $hv->stop_domain('vm.test'), 'a running domain stops';
    is( $stopped, 1, 'by being destroyed, which is libvirt for switched off' );

    $mock->redefine( _domain => sub { FakeStoppableDomain->new( 0, \$stopped ) } );
    ok $hv->stop_domain('vm.test'), 'one that is already off is nothing to do';
    is( $stopped, 1, 'and is not asked twice' );

    $mock->redefine( _domain => sub { undef } );
    ok !$hv->stop_domain('vm.test'), 'and a domain that is not there says so';
};

subtest 'the rollback point is a disk-only snapshot, or is not taken at all' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my @asked;
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( rollback_possible => sub { 1 } );
    $mock->redefine( create_snapshot   => sub { my ( undef, undef, $snapname, %o ) = @_; push @asked, [ $snapname, $o{disk_only}, $o{leave_down} ]; return 1 } );

    my $name = $hv->snapshot_before_rebuild( 'vm.test', capacity => 42949672960 );

    like( $name, qr/\A before-reprovision- \d{4}-\d{2}-\d{2}-\d{6} \z/, 'the name is the day and second an operator reads back and types at bin/restore' );

    # Disk only, and not merely as an economy.  The guest is about to be
    # rebuilt, so its memory is worth nothing -- and on libvirt asking for
    # disk_only is what takes the domain down, which is the only state that
    # backend will snapshot a disk in.  Left down for the same reason: the
    # rebuild takes it apart next, so starting it here would be to stop it again.
    is_deeply( \@asked, [ [ $name, 1, 1 ] ], 'taken disk-only and left down, which is what the rebuild wants of both backends' );

    # create_snapshot warns and returns false rather than dying, and the name is
    # what the caller offers an operator as the way home.
    $mock->redefine( create_snapshot => sub { return 0 } );
    is( $hv->snapshot_before_rebuild( 'vm.test', capacity => 1 ), undef, 'a snapshot that would not take is no rollback point' );

    @asked = ();
    $mock->redefine( rollback_possible => sub { 0 } );
    is( $hv->snapshot_before_rebuild( 'vm.test', capacity => 1 ), undef, 'and nothing worth going back to is not snapshotted at all' );
    is_deeply( \@asked, [], 'nor is anything asked of the backend for a snapshot that is not coming' );
};

{

    package FakeSnapshotDomain;

    sub new       { my ( $class, $active, $seen, $refuse ) = @_; return bless { active => $active, seen => $seen, refuse => $refuse }, $class }
    sub is_active { my ($self) = @_; return $self->{active} }
    sub destroy   { my ($self) = @_; $self->{active} = 0; push @{ $self->{seen} }, 'destroy'; return 1 }
    sub create    { my ($self) = @_; $self->{active} = 1; push @{ $self->{seen} }, 'create';  return 1 }

    sub create_snapshot {
        my ( $self, $xml, $flags ) = @_;
        push @{ $self->{seen} }, { xml => $xml, flags => $flags };
        die "libvirt would not take it\n" if $self->{refuse};
        return 1;
    }
}

subtest 'a running guest is snapshotted whole, and only disk_only takes it down' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    # The XML and the flags, which nothing exercised before: t/snapshot.t
    # redefines create_snapshot in every case, so a combination libvirt refuses
    # outright was able to ship and sit here.
    my @seen;
    my $running = FakeSnapshotDomain->new( 1, \@seen );
    my $mock    = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( _domain => sub { $running } );

    ok( $hv->create_snapshot( 'vm.test', 'whole' ), 'a running guest is snapshotted' );
    like( $seen[0]{xml}, qr{<memory[ ]snapshot='internal'/>}, 'with its memory in the XML, which is what makes it a full system snapshot' );
    ok( !( $seen[0]{flags} & Sys::Virt::DomainSnapshot::CREATE_LIVE() ), 'and without LIVE, which asks not to pause the guest and is only allowed when the memory goes outside the disk' );
    ok( !( grep { $_ eq 'destroy' } @seen ),                             'and the guest is left running, which is the point of a live snapshot' );

    @seen = ();
    my $stoppable = FakeSnapshotDomain->new( 1, \@seen );
    $mock->redefine( _domain => sub { $stoppable } );

    ok( $hv->create_snapshot( 'vm.test', 'disk', disk_only => 1 ), 'and disk_only is snapshotted too' );
    is( $seen[0], 'destroy', 'having taken the guest down first, which is the only state libvirt snapshots a disk in' );
    unlike( $seen[1]{xml}, qr/<memory/, 'no memory in the XML' );
    ok( !( $seen[1]{flags} & Sys::Virt::DomainSnapshot::CREATE_LIVE() ), 'and no LIVE here either, which nothing this takes is ever allowed to carry' );
    is( $seen[2], 'create', 'and the guest goes back up, an operator having asked for a snapshot rather than a shutdown' );

    # The rebuild path, which is about to take the guest apart: starting it here
    # would only be to stop it again a moment later.
    @seen = ();
    my $doomed = FakeSnapshotDomain->new( 1, \@seen );
    $mock->redefine( _domain => sub { $doomed } );

    ok( $hv->create_snapshot( 'vm.test', 'doomed', disk_only => 1, leave_down => 1 ), 'leave_down snapshots as well' );
    is( $seen[0], 'destroy', 'stopping the guest' );
    ok( !( grep { $_ eq 'create' } @seen ), 'and leaving it down, which is what that caller asked for' );

    # A guest that was running when we were handed it goes back up even when
    # libvirt would not take the snapshot.  Leaving it off because the snapshot
    # failed is the surprise this whole option exists to avoid.
    @seen = ();
    my $refused = FakeSnapshotDomain->new( 1, \@seen, 'refuse' );
    $mock->redefine( _domain => sub { $refused } );

    my @warned;
    {
        local $SIG{__WARN__} = sub { push @warned, @_ };
        ok( !$hv->create_snapshot( 'vm.test', 'nope', disk_only => 1 ), 'a snapshot libvirt will not take says so' );
    }
    like( $warned[0], qr/Snapshot[ ]of[ ]vm[.]test[ ]failed/, 'and says why' );
    is( $seen[-1], 'create', 'and the guest still goes back up, a refusal being no reason to leave it off' );

    # The case an operator hits without asking for anything: a guest that is
    # already off has no memory to capture, so there is only one snapshot to
    # take of it.
    @seen = ();
    my $off = FakeSnapshotDomain->new( 0, \@seen );
    $mock->redefine( _domain => sub { $off } );

    ok( $hv->create_snapshot( 'vm.test', 'cold' ), 'a guest that is already off is snapshotted without disk_only being asked for' );
    unlike( $seen[0]{xml}, qr/<memory/, 'with no memory element, there being no memory' );
    ok( !( $seen[0]{flags} & Sys::Virt::DomainSnapshot::CREATE_LIVE() ), 'and no LIVE, there being neither a guest to leave running nor memory to write' );
};

subtest 'the disk is copied aside as a volume of its own, with the guest stopped' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my @did;
    my $pool = FakeBuildPool->new( [] );
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( volume      => sub { FakeBuildVolume->new( '/opt/terraform/disks/vm.test-qcow2', 42949672960 ) } );
    $mock->redefine( volume_path => sub { undef } );
    $mock->redefine( pool        => sub { $pool } );
    $mock->redefine( stop_domain => sub { push @did, 'stop_domain'; return 1 } );

    my $path = quietly( sub { $hv->clone_guest_disk('vm.test') } );

    is( $path,   '/opt/terraform/disks/vm.test.bak-qcow2', 'the copy is a volume of its own, named for the guest it came from' );
    is( $did[0], 'stop_domain',                            'and the guest was stopped before it was read, a live qcow2 copying torn' );

    my ($cloned) = $pool->cloned;
    like( $cloned->{xml}, qr{<name>vm[.]test[.]bak-qcow2</name>}, 'libvirt was asked for that name' );

    # The claim the POD makes: a backup that depends on the base image the guest
    # was laid over stops working the day somebody prunes it.
    unlike( $cloned->{xml}, qr/backingStore/, 'and for a volume standing on its own, with no backing store declared' );

    # Rebuilding twice running is exactly when writing over the older copy would
    # take the one that was wanted.
    @did = ();
    $mock->redefine( volume_path => sub { '/opt/terraform/disks/vm.test.bak-qcow2' } );
    my $kept = quietly( sub { $hv->clone_guest_disk('vm.test') } );
    is( $kept, '/opt/terraform/disks/vm.test.bak-qcow2', 'a copy that is there already is handed back' );
    is_deeply( \@did, [], 'without stopping the guest or copying over it' );

    $mock->redefine( volume_path => sub { undef } );
    $mock->redefine( volume      => sub { undef } );
    is( quietly( sub { $hv->clone_guest_disk('vm.test') } ), undef, 'and a guest with no disk has none to copy' );

    # A refusal has to read as "no copy", since the caller rebuilds over the
    # disk only when it is told one was made.
    my @warned;
    {
        local $SIG{__WARN__} = sub { push @warned, @_ };
        $mock->redefine( volume => sub { FakeBuildVolume->new( '/opt/terraform/disks/vm.test-qcow2', 42949672960 ) } );
        $mock->redefine( pool   => sub { FakeBuildPool->new( [], refuse => 1 ) } );
        is( quietly( sub { $hv->clone_guest_disk('vm.test') } ), undef, 'a copy libvirt would not make is no copy' );
    }
    like( $warned[0], qr/Could[ ]not[ ]copy[ ]vm[.]test/, 'and it says so rather than passing silently' );
};

subtest 'a rebuild that cannot keep the disk is one that destroys the guest' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists => sub { 1 } );
    $mock->redefine( disk_reusable => sub { 0 } );

    ok( $hv->rebuild_destroys_guest( 'vm.test', capacity => 42949672960 ), 'a guest whose disk cannot be kept is one the rebuild takes apart' );

    $mock->redefine( disk_reusable => sub { 1 } );
    ok( !$hv->rebuild_destroys_guest( 'vm.test', capacity => 42949672960 ), 'and one whose disk can be kept is built over instead' );

    # A first build has nothing to lose, and stopping to ask about one would
    # stop every new domain there is.
    $mock->redefine( domain_exists => sub { 0 } );
    $mock->redefine( disk_reusable => sub { 0 } );
    ok( !$hv->rebuild_destroys_guest( 'vm.test', capacity => 42949672960 ), 'and a domain that is not there yet has nothing to destroy' );
};

subtest 'starting a domain leaves it running' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my @seen;
    my $off  = FakeSnapshotDomain->new( 0, \@seen );
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( _domain => sub { $off } );

    ok( $hv->start_domain('vm.test'), 'a domain that is off starts' );
    is_deeply( \@seen, ['create'], 'by being created, which is libvirt for switched on' );

    @seen = ();
    my $on = FakeSnapshotDomain->new( 1, \@seen );
    $mock->redefine( _domain => sub { $on } );

    ok( $hv->start_domain('vm.test'), 'one that is already running is nothing to do' );
    is_deeply( \@seen, [], 'and is not asked twice' );

    $mock->redefine( _domain => sub { undef } );
    ok( !$hv->start_domain('vm.test'), 'and a domain that is not there says so' );
};

subtest 'a domain that already exists hands back the uuid libvirt gave it' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my $ignored = 0;
    my $mock    = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( _domain => sub { FakeStoppableDomain->new( 0, \$ignored ) } );

    is( $hv->domain_uuid('vm.test'), '35341952-6f2b-457a-a882-80f6c47e2d2c', 'the uuid it is already bound to' );

    # Undef rather than an error: a first build has no domain to ask, and the
    # template leaves the element out so libvirt mints one.  The rebuild that
    # keeps a disk is the only caller that finds anything here.
    $mock->redefine( _domain => sub { undef } );
    is( $hv->domain_uuid('vm.test'), undef, 'and nothing at all for a domain that does not exist yet' );
};

subtest 'a rebuild that keeps the disk stops the guest rather than undefining it' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my ( @did, @deleted );
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( stop_domain        => sub { push @did,     'stop_domain';       return 1 } );
    $mock->redefine( annihilate_domain  => sub { push @did,     'annihilate_domain'; return 1 } );
    $mock->redefine( revert_disk        => sub { push @did,     "revert $_[2]";      return 1 } );
    $mock->redefine( delete_volume      => sub { push @deleted, $_[1];               return 1 } );
    $mock->redefine( release_dhcp_lease => sub { push @did,     'release';           return 1 } );
    $mock->redefine( domain_exists      => sub { 1 } );
    $mock->redefine( guest_mac          => sub { '52:54:00:aa:bb:cc' } );
    $mock->redefine( lease_ips          => sub { return ('192.168.122.9') } );

    quietly( sub { $hv->clear_guest( 'vm.test', keep_disk => 1 ) } );

    ok( ( grep { $_ eq 'stop_domain' } @did ),          'the guest is stopped' );
    ok( !( grep { $_ eq 'annihilate_domain' } @did ),   'and not undefined, which would take the record libvirt keeps of its snapshots' );
    ok( ( grep { $_ eq 'revert trog-pristine' } @did ), 'the disk goes back to the state it was made in' );
    is_deeply( \@deleted, ['vm.test-cloudinit.iso'], 'the seed goes and the disk stays' );
    ok( ( grep { $_ eq 'release' } @did ), 'and the leases are released, which has nothing to do with the disk' );
};

subtest 'a rebuild that cannot keep the disk clears all of it, the way it always did' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my ( @did, @deleted );
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( stop_domain        => sub { push @did,     'stop_domain';       return 1 } );
    $mock->redefine( annihilate_domain  => sub { push @did,     'annihilate_domain'; return 1 } );
    $mock->redefine( revert_disk        => sub { push @did,     'revert';            return 1 } );
    $mock->redefine( delete_volume      => sub { push @deleted, $_[1];               return 1 } );
    $mock->redefine( release_dhcp_lease => sub { return 1 } );
    $mock->redefine( domain_exists      => sub { 1 } );
    $mock->redefine( guest_mac          => sub { '52:54:00:aa:bb:cc' } );
    $mock->redefine( lease_ips          => sub { return ('192.168.122.9') } );

    quietly( sub { $hv->clear_guest('vm.test') } );

    is_deeply( \@deleted, [ 'vm.test-qcow2', 'vm.test-cloudinit.iso' ], 'both volumes go' );
    ok( ( grep { $_ eq 'annihilate_domain' } @did ), 'the domain is undefined' );
    ok( !( grep { $_ eq 'revert' } @did ),           'and nothing is reverted, there being nothing kept to revert' );
};

subtest 'a disk is snapshotted the moment it is made, while it is still empty' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my ( @created, @snapped );
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( volume_path   => sub { undef } );
    $mock->redefine( pool          => sub { FakeBuildPool->new( \@created ) } );
    $mock->redefine( snapshot_disk => sub { push @snapped, [ $_[1], $_[2] ]; return 1 } );

    quietly( sub { $hv->create_disk( 'vm.test-qcow2', backing => '/base', capacity => 42949672960 ) } );

    is_deeply(
        \@snapped, [ [ 'vm.test-qcow2', 'trog-pristine' ] ],
        'taken against the disk just created, because there is no later moment when it is empty'
    );

    # The failure that actually happens, rather than the one that is easy to
    # imagine: qemu-img refusing a disk it may not open exits non-zero, which is
    # a false return and not an exception.  Measured on a hypervisor, where the
    # pristine snapshot was silently never taken and the build said nothing.
    {
        @snapped = ();
        my @refused;
        local $SIG{__WARN__} = sub { push @refused, @_ };
        $mock->redefine( snapshot_disk => sub { return 0 } );

        my $still = quietly( sub { $hv->create_disk( 'vm.test-qcow2', backing => '/base', capacity => 42949672960 ) } );
        is( $still, '/opt/terraform/disks/vm.test-qcow2', 'a disk qemu-img would not snapshot is still built' );
        like( $refused[0], qr/cannot [ ] be [ ] rolled [ ] back/, 'and the rollback it will not have is said out loud' );
    }

    # Best effort: a disk that could not be snapshotted is still built, and
    # rollback_possible is what notices afterwards that there is nowhere to go
    # back to.  A build that stopped here would be a worse trade.
    @snapped = ();
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    $mock->redefine( snapshot_disk => sub { die "no qemu-img on this hypervisor\n" } );

    my $path = quietly( sub { $hv->create_disk( 'vm.test-qcow2', backing => '/base', capacity => 42949672960 ) } );

    is( $path, '/opt/terraform/disks/vm.test-qcow2', 'the disk is built regardless' );
    like( $warned[0], qr/cannot [ ] be [ ] rolled [ ] back/, 'and the rollback it will not have is said out loud' );
};

subtest 'the cloud-init seed is an ISO labelled cidata' => sub {
    my $hv = fresh( uri => 'qemu+ssh://root@hv/system' );

    my ( @ran, %written );
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( mkpath       => sub { 1 } );
    $mock->redefine( write_text   => sub { $written{ $_[1] } = $_[2]; return 1 } );
    $mock->redefine( refresh_pool => sub { 1 } );
    $mock->redefine( iso_maker    => sub { 'xorriso' } );
    $mock->redefine( run_cmd      => sub { my ( $s, @c ) = @_; push @ran, [@c]; return 0 } );

    my $path = quietly(
        sub {
            $hv->cloudinit_iso(
                'vm.example.test',
                'user-data'      => "#cloud-config\n",
                'meta-data'      => "instance-id: vm\n",
                'network-config' => "version: 1\n"
            );
        }
    );

    is( $path, '/opt/terraform/disks/vm.example.test-cloudinit.iso', 'lands in the pool' );

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
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( volume_path  => sub { undef } );
    $mock->redefine( refresh_pool => sub { 1 } );
    $mock->redefine( run_cmd      => sub { my ( $s, @c ) = @_; push @ran, join( ' ', @c ); return 0 } );

    quietly( sub { $hv->base_image('https://example.test/noble.img') } );

    ok(
        ( grep { m/curl[ ]\N*\.partial/ } @ran ),
        'downloaded to a partial name, so libvirt never sees a half a file'
    );
    ok( ( grep { m/\Amv[ ]\N*\.partial[ ]/ } @ran ), 'and moved into place after' );

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
    like( exception { $hv->base_image(undef) }, qr/No[ ]image[ ]URL[ ]configured/, 'and nothing to fetch is an error' );
};

{

    package FakeBuildPool;

    sub new { my ( $class, $created, %opts ) = @_; return bless { created => $created, %opts }, $class }

    sub create_volume {
        my ( $self, $xml ) = @_;
        push @{ $self->{created} }, $xml;
        my ($name) = $xml =~ m{<name>([^<]+)</name>};
        return FakeBuildVolume->new("/opt/terraform/disks/$name");
    }

    sub cloned ($self) { return @{ $self->{cloned} // [] } }

    sub clone_volume {
        my ( $self, $xml, $source ) = @_;
        die "libvirt would not copy it\n" if $self->{refuse};
        push @{ $self->{cloned} }, { xml => $xml, from => $source };
        my ($name) = $xml =~ m{<name>([^<]+)</name>};
        return FakeBuildVolume->new("/opt/terraform/disks/$name");
    }
}

{

    package FakeBuildVolume;

    sub new { my ( $class, $path, $capacity ) = @_; return bless { path => $path, capacity => $capacity }, $class }
    sub get_path ($self) { return $self->{path} }
    sub get_info ($self) { return { capacity => $self->{capacity} // 42949672960 } }
}

sub quietly {
    my ($code) = @_;
    my ( undef, @result ) = capture_stdout { $code->() };
    return wantarray ? @result : $result[0];
}

# --- Guest identity, which is what makes device names knowable ---------------
subtest 'a guest MAC is derived from its name and does not move' => sub {
    my $hv = fresh();

    my $nat    = $hv->guest_mac( 'vm.example.test', 0 );
    my $bridge = $hv->guest_mac( 'vm.example.test', 1 );

    like( $nat, qr/\A52:54:00(:[\da-f]{2}){3}\z/, 'a QEMU-prefixed MAC' );
    isnt( $nat, $bridge, 'the two interfaces differ' );

    is(
        $hv->guest_mac( 'vm.example.test', 0 ), $nat,
        'the same guest gets the same MAC every time, so its lease survives a rebuild'
    );
    isnt( $hv->guest_mac( 'other.example.test', 0 ), $nat, 'a different guest does not' );

    # Any hypervisor agrees, since it comes from the name and nothing else.
    is(
        fresh( uri => 'qemu+ssh://hv2/system' )->guest_mac( 'vm.example.test', 0 ), $nat,
        'and so does another hypervisor'
    );

    is_deeply( [ $hv->nic_slots ], [ 3, 4 ], 'the slots are pinned, so a guest calls its interfaces the same thing every time' );
};

subtest 'what a guest will call its interfaces is the hypervisor to say' => sub {
    my $hv = fresh();

    is_deeply( [ $hv->nic_names ], [qw{ens3 ens4}], 'the prefix and the pinned slots, NAT first' );

    # 'ens' is systemd's answer for a PCI NIC on the i440fx the domain XML asks
    # for.  Another machine type names them another way -- enp0s3 is the common
    # one -- so the two places that write a network configuration ask for the
    # name rather than building one out of a prefix they assumed.
    {

        package Trog::HV::Weird;
        use parent -norequire, 'Trog::HV::Libvirt';
        sub nic_prefix { return 'enp0s' }
    }

    is_deeply(
        [ bless( {%$hv}, 'Trog::HV::Weird' )->nic_names ],
        [qw{enp0s3 enp0s4}],
        'and a hypervisor whose guests name them otherwise says so once'
    );
};

subtest 'leases are looked up by MAC, not by name' => sub {
    my $hv = fresh( uri => 'qemu+ssh://hv/system' );

    my @asked;
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( vmm => sub { FakeLeaseVMM->new( \@asked ) } );

    is( $hv->lease_ip( 'default', mac => '52:54:00:aa:bb:cc' ), '192.168.122.50',    'found' );
    is( $asked[0],                                              '52:54:00:aa:bb:cc', 'and dnsmasq was asked about that MAC, not sifted afterwards' );

    # The hostname match is still there, and is still a substring match: a guest
    # called vm.example.test matches a lease for sub.vm.example.test.
    is( $hv->lease_ip( 'default', hostname => 'vm.example.test' ), '192.168.122.50', 'hostname still works' );
    is( $hv->lease_ip( 'default', hostname => 'nothing.here' ),    undef,            'and misses when it should' );
};

{

    package FakeLeaseVMM;

    sub new                              { my ( $class, $asked ) = @_; return bless { asked => $asked }, $class }
    sub get_network_by_name ( $self, $ ) { return FakeNet->new( $self->{asked} ) }
}

{

    package FakeNet;

    # What dnsmasq has on file, in the order it lists them, when a test says;
    # one lease otherwise.  The default is in the sub rather than on the
    # variable, because this block runs after the subtests above it do.
    our @LEASES;

    sub new { my ( $class, $asked ) = @_; return bless { asked => $asked }, $class }

    sub get_dhcp_leases {
        my ( $self, $mac ) = @_;
        push @{ $self->{asked} }, $mac;
        return @LEASES if @LEASES;
        return ( { ipaddr => '192.168.122.50', mac => '52:54:00:aa:bb:cc', hostname => 'vm.example.test' } );
    }
}

subtest 'a rebuilt guest can hold two leases, and the newest is the address it has' => sub {
    my $hv = fresh( uri => 'qemu+ssh://hv/system' );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( vmm => sub { FakeLeaseVMM->new( [] ) } );

    # Measured on hydra: a guest rebuilt under the same name kept its MAC, got
    # 192.168.122.97, and dnsmasq kept its old 192.168.122.96 on file too --
    # which is what collect_artifacts and ask_guest then connected to, and hung
    # on, for as long as ssh would wait for an address nobody was at.
    my $mac   = '52:54:00:9c:8b:34';
    my @stale = ( { ipaddr => '192.168.122.96', mac => $mac, expirytime => 1_788_997_000 } );
    my @now   = ( { ipaddr => '192.168.122.97', mac => $mac, expirytime => 1_789_000_600 } );

    local @FakeNet::LEASES = ( @stale, @now );
    is( $hv->lease_ip( 'default', mac => $mac ), '192.168.122.97', 'the newer of the two' );

    local @FakeNet::LEASES = ( @now, @stale );
    is( $hv->lease_ip( 'default', mac => $mac ), '192.168.122.97', 'in whichever order dnsmasq lists them' );

    # All of them, for releasing what the guests before this one left behind.
    is_deeply( [ $hv->lease_ips( 'default', mac => $mac ) ], [qw{192.168.122.97 192.168.122.96}], 'and every one of them, newest first' );
};

subtest 'a command that names its own timeout is not called hung before it' => sub {

    # _unhang exists to notice a command that should return promptly and does
    # not.  wait_for_makefile's is `sudo timeout 180m bash -c 'until atq is
    # empty ...'`, which is meant to block for as long as the guest takes to
    # build -- and the ten minute alarm killed it regardless, so every setup
    # timeout above ten minutes was decorative and a guest still compiling came
    # back as a failure.  Only the remote path reaches _unhang, which is why
    # this never appeared against a local hypervisor.
    is(
        Trog::Machine::_hang_limit('virsh list --all'), $Trog::Machine::HANG_TIMEOUT,    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        'an ordinary command gets the default'
    );

    is(
        Trog::Machine::_hang_limit("sudo timeout 180m bash -c 'until :; do :; done'"),    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        180 * 60 + 60, 'one that says 180m gets 180m and a minute'
    );

    is(
        Trog::Machine::_hang_limit('sudo timeout 90 something'), $Trog::Machine::HANG_TIMEOUT,    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
        'and one shorter than the default does not lower it'
    );

    is( Trog::Machine::_hang_limit(undef), $Trog::Machine::HANG_TIMEOUT, 'undef is the default' );    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
};

# --- What libvirt refuses stops the run ---------------------------------------
subtest 'libvirt refusing to set up, start or remove something is an error' => sub {
    my %refuse;
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( vmm       => sub { FakeRefusingVMM->new( \%refuse ) } );
    $mock->redefine( _domain   => sub { FakeRefusing->new( \%refuse ) } );
    $mock->redefine( pool_path => sub { '/bogus/pool' } );

    my $hv = fresh( uri => 'qemu+ssh://hv/system' );
    is( exception { $hv->define_domain('<domain/>') }, undef, 'nothing refused, nothing to say' );

    %refuse = ( set_autostart => 1 );
    like( exception { $hv->define_domain('<domain/>') }, qr/Could[ ]not[ ]set[ ]vm\.test[ ]to[ ]start[ ]with[ ]the[ ]host:[ ]set_autostart[ ]refused/, 'a domain that will not autostart' );    ## no critic (RegularExpressions::ProhibitComplexRegexes)

    %refuse = ( create => 1 );
    like( exception { $hv->define_domain('<domain/>') }, qr/Could[ ]not[ ]start[ ]vm\.test:[ ]create[ ]refused/, 'a domain that will not start' );

    %refuse = ( build => 1 );
    like(
        exception {
            quietly( sub { fresh( uri => 'qemu+ssh://hv/system' )->pool } )
        },
        qr/Could[ ]not[ ]build[ ]the[ ]storage[ ]pool[ ]tf_disks[ ]at[ ]\/bogus\/pool:[ ]build[ ]refused/,    ## no critic (RegularExpressions::ProhibitComplexRegexes)
        'a pool that will not build'
    );

    %refuse = ( create => 1 );
    like(
        exception {
            quietly( sub { fresh( uri => 'qemu+ssh://hv/system' )->pool } )
        },
        qr/Could[ ]not[ ]start[ ]the[ ]storage[ ]pool[ ]tf_disks:[ ]create[ ]refused/,                        ## no critic (RegularExpressions::ProhibitComplexRegexes)
        'a pool that will not start'
    );

    %refuse = ( refresh => 1 );
    like(
        exception {
            quietly( sub { fresh( uri => 'qemu+ssh://hv/system' )->refresh_pool } )
        },
        qr/Could[ ]not[ ]refresh[ ]the[ ]storage[ ]pool[ ]tf_disks:[ ]refresh[ ]refused/,                     ## no critic (RegularExpressions::ProhibitComplexRegexes)
        'a pool that will not refresh'
    );

    %refuse = ( undefine => 1 );
    like( exception { $hv->annihilate_domain('vm.test') }, qr/Could[ ]not[ ]undefine[ ]vm\.test:[ ]undefine[ ]refused/, 'a domain that will not go' );

    %refuse = ( destroy => 1 );
    is( $hv->annihilate_domain('vm.test'), 1, 'one that is already off is not stopped at all, so it still goes' );

    %refuse = ( destroy => 1, running => 1 );
    like( exception { $hv->annihilate_domain('vm.test') }, qr/Could[ ]not[ ]stop[ ]vm\.test:[ ]destroy[ ]refused/, 'but a running one that will not stop is an error' );
};

{

    package FakeRefusingVMM;

    sub new                      ( $class, $refuse ) { return bless { refuse => $refuse }, $class }
    sub get_storage_pool_by_name ( $self, $ )        { die "no such pool\n" }
    sub define_storage_pool      ( $self, $ )        { return FakeRefusing->new( $self->{refuse} ) }
    sub define_domain            ( $self, $ )        { return FakeRefusing->new( $self->{refuse} ) }
}

{

    package FakeRefusing;

    # A pool or a domain, refusing whatever the test has named, and running only
    # when it names that too.
    sub new           ( $class, $refuse ) { return bless { refuse => $refuse }, $class }
    sub get_name      ($self)             { return 'vm.test' }
    sub is_active     ($self)             { return $self->{refuse}{running} ? 1 : 0 }
    sub set_autostart ( $self, $ )        { return $self->_or_refuse('set_autostart') }
    sub create        ($self)             { return $self->_or_refuse('create') }
    sub build         ( $self, $ )        { return $self->_or_refuse('build') }
    sub refresh       ($self)             { return $self->_or_refuse('refresh') }
    sub destroy       ($self)             { return $self->_or_refuse('destroy') }
    sub undefine      ( $self, @ )        { return $self->_or_refuse('undefine') }

    sub _or_refuse ( $self, $what ) {
        die "$what refused\n" if $self->{refuse}{$what};
        return 1;
    }
}

done_testing;
