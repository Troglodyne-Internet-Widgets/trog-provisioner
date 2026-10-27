#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/runner_account.t - bin/runner_account: the account it makes on a hypervisor,
and what it refuses to make or take away

=head1 DESCRIPTION

The hypervisor is a fake: a hash of what it has, and mocks of the
L<Trog::HV::Libvirt> calls that ask it and change it.  A second run against
what the first one left is how the test knows each step asks before it acts.

=cut

use Test::More;
use Capture::Tiny    qw{capture_stdout};
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempdir};
use File::Slurper::Temp();
use File::Which();
use IPC::Run3();
use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- set before anything reads the configuration directory.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

# Loaded so Test::MockModule has a package to attach to.
use Trog::HV::Libvirt();                                                                             ## no critic (ProhibitUnusedImports)

my $script = "$FindBin::Bin/../bin/runner_account";
require_ok($script) or BAIL_OUT("$script does not load");

my $dir    = tempdir( CLEANUP => 1 );
my $hvconf = "$dir/hypervisors.conf";
File::Slurper::Temp::write_text( $hvconf, "[hv1]\nlibvirt_uri = qemu+ssh://someadmin\@hv.test.test/system\n" );

my $keyfile = "$dir/operator.pub";
File::Slurper::Temp::write_text( $keyfile, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogus operator\@test.test\n" );

my @create = ( '--hvconf', $hvconf, qw{--hypervisor hv1 --user runner --pool-name runner_disks --pool-path /bogus/vm-disks/runner --quota 500G}, qw{--partition /machine/runner --cpu-quota 400% --io-weight 50}, '--authorize', $keyfile );
my @remove = ( '--hvconf', $hvconf, qw{--hypervisor hv1 --user runner --pool-name runner_disks --pool-path /bogus/vm-disks/runner --partition /machine/runner --remove} );

# What the fake hypervisor has.  Each test starts from a fresh one.
sub fresh_state {
    return {
        sudo     => 'Sudo version 1.9.15p5',
        fstype   => { '/bogus/vm-disks'              => 'zfs' },
        datasets => { 'tank/vm-disks'                => { mountpoint => '/bogus/vm-disks' } },
        files    => { '/usr/libexec/virtiofs-better' => q{}, '/usr/lib/libvirt/libvirt_leaseshelper' => q{} },
        users    => {},
        pools    => {},
        dirs     => {},
        root     => [],
    };
}

# The dataset whose mountpoint is the longest prefix of $path, as zfs list
# answers for a path.
sub dataset_holding ( $state, $path ) {
    my @holding = sort { length $a <=> length $b } grep { index( "$path/", "$state->{datasets}{$_}{mountpoint}/" ) == 0 } keys %{ $state->{datasets} };
    return $holding[-1] // q{};
}

# What the fake answers to each command it is asked, by the first words of the
# command.  Each answer gets the state and the first quoted argument.
my @ANSWERS = (
    [ 'sudo -V'                        => sub ( $s, $arg ) { $s->{sudo} } ],
    [ 'command -v qemu-img'            => sub ( $s, $arg ) { '/usr/bin/qemu-img' } ],
    [ 'mktemp'                         => sub ( $s, $arg ) { '/tmp/staged' } ],
    [ 'stat -f'                        => sub ( $s, $arg ) { $s->{fstype}{$arg} } ],
    [ 'zfs list -H -o name'            => sub ( $s, $arg ) { index( $arg, q{/} ) == 0 ? dataset_holding( $s, $arg ) : exists $s->{datasets}{$arg} ? $arg : undef } ],
    [ 'zfs get -H -o value mountpoint' => sub ( $s, $arg ) { $s->{datasets}{$arg}{mountpoint} } ],
    [ 'zfs get -H -o value quota'      => sub ( $s, $arg ) { $s->{datasets}{$arg}{quota} } ],
    [ 'getent passwd'                  => sub ( $s, $arg ) { $s->{users}{$arg} ? "/home/$arg"                                       : undef } ],
    [ 'id -nG'                         => sub ( $s, $arg ) { $s->{users}{$arg} ? join( q{ }, $arg, @{ $s->{users}{$arg}{groups} } ) : undef } ],
    [ 'id -u'                          => sub ( $s, $arg ) { $s->{users}{$arg} ? 1001                                               : undef } ],
    [ 'id -g'                          => sub ( $s, $arg ) { $s->{users}{$arg} ? 1001                                               : undef } ],
    [ 'sudo -n cat'                    => sub ( $s, $arg ) { $s->{files}{$arg} } ],
    [ 'sudo -n find'                   => sub ( $s, $arg ) { $s->{dirs}{$arg} } ],
);

# What each root command does to the state, by its first words.  Each gets the
# state and the arguments, and returns the exit status.
my @ROOT = (
    [ 'useradd'     => sub ( $s, @a ) { $s->{users}{ $a[-1] } = { groups => [] };           0 } ],
    [ 'usermod'     => sub ( $s, @a ) { push @{ $s->{users}{ $a[-1] }{groups} }, 'libvirt'; 0 } ],
    [ 'sh'          => sub ( $s, @a ) { $s->{files}{ $a[-2] } .= "$a[-3]\n";                0 } ],
    [ 'zfs create'  => sub ( $s, @a ) { $s->{datasets}{ $a[-1] } = { mountpoint => '/bogus/vm-disks/runner', quota => substr( $a[-2], length 'quota=' ) }; 0 } ],
    [ 'zfs set'     => sub ( $s, @a ) { $s->{datasets}{ $a[-1] }{quota} = substr( $a[-2], length 'quota=' ); 0 } ],
    [ 'zfs destroy' => sub ( $s, @a ) { delete $s->{datasets}{ $a[-1] }; 0 } ],
    [ 'visudo'      => sub ( $s, @a ) { $s->{visudo_refuses} ? 1 : 0 } ],
    [ 'install -d'  => sub ( $s, @a ) { 0 } ],
    [ 'install'     => sub ( $s, @a ) { $s->{files}{ $a[-1] } = $s->{files}{ $a[-2] }; 0 } ],
    [ 'rm -f'       => sub ( $s, @a ) { delete $s->{files}{ $a[-1] };                  0 } ],
    [ 'userdel'     => sub ( $s, @a ) { delete $s->{users}{ $a[-1] };                  0 } ],
    [ 'systemctl daemon-reload' => sub ( $s, @a ) { 0 } ],
);

# The first entry of @$table whose words begin $command, or a death that names
# the command, so that a step the fake does not know fails the test.
sub entry_for ( $table, $command ) {
    my ($entry) = grep { index( "$command ", "$_->[0] " ) == 0 } @$table;
    return $entry->[1] // die "the fake hypervisor was not expecting: $command\n";
}

# Runs $code with Trog::HV::Libvirt answering from $state, and returns what
# $code returns.
sub with_hypervisor ( $state, $code ) {
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');

    $mock->redefine(
        capture_cmd => sub ( $hv, $cmd ) {
            $cmd =~ s/\s+2>\/dev\/null\z//;
            my ($arg) = $cmd =~ m/'([^']*)'/;
            return entry_for( \@ANSWERS, $cmd )->( $state, $arg // q{} ) // q{};
        }
    );
    $mock->redefine(
        run_sudo => sub ( $hv, @argv ) {
            push @{ $state->{root} }, "@argv";
            return entry_for( \@ROOT, "@argv" )->( $state, @argv );
        }
    );
    $mock->redefine(
        run_cmd => sub ( $hv, @argv ) {
            die "the fake hypervisor was not expecting: @argv\n" unless "@argv[0..4]" eq 'sudo -n test ! -e';
            return exists $state->{files}{ $argv[-1] } ? 1 : 0;
        }
    );
    $mock->redefine(
        write_text => sub ( $hv, $path, $text, %opts ) {
            chomp( $state->{files}{$path} = $text );
            return 1;
        }
    );
    $mock->redefine( file_exists => sub ( $hv, $path ) { exists $state->{files}{$path} ? 1 : 0 } );
    $mock->redefine( remove      => sub ( $hv, $path ) { delete $state->{files}{$path}; 1 } );
    $mock->redefine( pool_target => sub ( $hv, $name ) { $state->{pools}{$name}{path} } );
    $mock->redefine(
        define_pool => sub ( $hv, $name, $path, %perm ) {
            $state->{pools}{$name} = { path => $path, %perm, volumes => [] };
            return Test::FakePool->new( $state, $name );
        }
    );
    $mock->redefine( vmm => sub ($hv) { Test::FakeVmm->new($state) } );

    return $code->();
}

{

    package Test::FakePool;
    sub new ( $class, $state, $name ) { return bless { state => $state, name => $name }, $class }
    sub is_active                     { return 1 }
    sub create                        { return 1 }
    sub destroy                       { return 1 }
    sub undefine ($self)              { delete $self->{state}{pools}{ $self->{name} }; return 1 }

    sub list_all_volumes ($self) {
        return map { Test::FakeVolume->new($_) } @{ $self->{state}{pools}{ $self->{name} }{volumes} };
    }

    package Test::FakeVolume;
    sub new      ( $class, $name ) { return bless { name => $name }, $class }
    sub get_name ($self)           { return $self->{name} }

    package Test::FakeVmm;
    sub new                      ( $class, $state ) { return bless { state => $state }, $class }
    sub get_storage_pool_by_name ( $self, $name )   { return Test::FakePool->new( $self->{state}, $name ) }
}

# systemd reads the unit, because a unit that systemd ignores sets no limit.
# Skips where this machine has no systemd-analyze.
sub reads_as_a_slice ($text) {
    my $analyze = File::Which::which('systemd-analyze');
  SKIP: {
        skip 'no systemd-analyze here to read the slice', 1 unless $analyze;
        my $unit = "$dir/machine-runner.slice";
        File::Slurper::Temp::write_text( $unit, "$text\n" );
        IPC::Run3::run3( [ $analyze, 'verify', $unit ], \undef, \my $out, \my $err );
        is( $? >> 8, 0, 'systemd-analyze verify takes the slice' ) or diag $out, $err;
    }
    return;
}

sub run_tool ( $state, @args ) {
    my $rc;
    my $said = with_hypervisor(
        $state,
        sub {
            capture_stdout { $rc = Trog::Bin::RunnerAccount::main(@args) }
        }
    );
    return ( $rc, $said );
}

subtest 'plan refuses what a step would read as syntax' => sub {
    my %ok = ( user => 'runner', 'pool-name' => 'runner_disks', 'pool-path' => '/bogus/vm-disks/runner', quota => '500G', authorize => [] );

    like( exception { Trog::Bin::RunnerAccount::plan( %ok, user        => 'Run ner' ) },       qr/not[ ]a[ ]name[ ]useradd[ ]takes/, 'a user useradd would refuse' );
    like( exception { Trog::Bin::RunnerAccount::plan( %ok, 'pool-path' => '/bogus/../etc' ) }, qr/absolute[ ]path/,                  'a pool path that climbs out' );
    like( exception { Trog::Bin::RunnerAccount::plan( %ok, 'pool-path' => 'relative/dir' ) },  qr/absolute[ ]path/,                  'a relative pool path' );
    like( exception { Trog::Bin::RunnerAccount::plan( %ok, quota       => 'lots' ) },          qr/not[ ]a[ ]size/,                   'a quota zfs cannot read' );
    like( exception { Trog::Bin::RunnerAccount::plan( %ok, partition   => '/runner' ) },       qr{has[ ]to[ ]be[ ]/machine/NAME},    'a partition outside /machine' );
    like( exception { Trog::Bin::RunnerAccount::plan( %ok, 'cpu-quota' => '400%' ) },          qr/need[ ]--partition/,               'a slice limit with no slice' );
    like( exception { Trog::Bin::RunnerAccount::plan( %ok, partition => '/machine/r', 'io-weight' => 0 ) }, qr/from[ ]1[ ]to[ ]10000/, 'an IOWeight systemd refuses' );

    my $plan = Trog::Bin::RunnerAccount::plan( %ok, partition => '/machine/runner' );
    is( $plan->{slice}, 'machine-runner.slice', 'the partition names the slice that libvirt puts the guests in' );
};

subtest 'a dry run asks, says, and changes nothing' => sub {
    my $state = fresh_state();

    my ( $rc, $said ) = run_tool( $state, @create, q{--dryrun} );
    is( $rc, 0, 'it exits 0' );
    is_deeply( $state->{root}, [], 'and runs nothing as root' );
    like( $said, qr/would[ ]make[ ]the[ ]user[ ]runner/,                        'it says it would make the user' );
    like( $said, qr{would[ ]make[ ]the[ ]ZFS[ ]dataset[ ]tank/vm-disks/runner}, 'and the dataset, a child of the one on the parent directory' );
    like( $said, qr/Nothing[ ]changed:[ ]8[ ]step/,                             'and counts every step' );
};

subtest 'a run makes the account, and a second run finds nothing to do' => sub {
    my $state = fresh_state();

    my ( $rc, $said ) = run_tool( $state, @create );
    is( $rc, 0, 'it exits 0' );
    is_deeply(
        $state->{users}{runner}{groups},
        ['libvirt'], 'the user exists, in the libvirt group',
    );
    like( $state->{files}{'/home/runner/.ssh/authorized_keys'}, qr/operator\@test[.]test/, 'the operator can log in as it, so bin/provision can add the key of the runner' );
    is( $state->{datasets}{'tank/vm-disks/runner'}{quota}, '500G', 'the dataset has the quota' );
    is_deeply( [ @{ $state->{pools}{runner_disks} }{qw{path owner group}} ], [ '/bogus/vm-disks/runner', 1001, 1001 ], 'the pool is on it, owned by the user' );
    my $slice = $state->{files}{'/etc/systemd/system/machine-runner.slice'};
    like( $slice, qr/CPUQuota=400%\nIOWeight=50/, 'the slice has the caps' );
    reads_as_a_slice($slice);

    my $grant = $state->{files}{'/etc/sudoers.d/90-trog-runner-runner'};
    like( $grant, qr/^runner[ ]ALL=\(root\)[ ]NOPASSWD:/m, 'the grant for the user is installed' );

    my @order       = map  { m/\A(\S+(?:[ ]\S+)?)/ ? $1 : $_ } @{ $state->{root} };
    my ($checked)   = grep { $order[$_]         =~ m/\Avisudo/ } 0 .. $#order;
    my ($installed) = grep { $state->{root}[$_] =~ m{sudoers[.]d} } 0 .. $#order;
    ok( defined $checked && $checked < $installed, 'visudo checks the file before it is installed' );

    $state->{root} = [];
    ( $rc, $said ) = run_tool( $state, @create );
    is_deeply( $state->{root}, [], 'the second run runs nothing as root' );
    like( $said, qr/Done:[ ]0[ ]step/,                                           'and says so' );
    like( $said, qr{libvirt_uri:[ ]qemu\+ssh://runner\@hv[.]test[.]test/system}, 'it prints the hypervisors entry, with the account in the URI' );

    # A changed quota is one step, not a rebuild.
    $state->{root} = [];
    run_tool( $state, map { $_ eq '500G' ? '1T' : $_ } @create );
    is_deeply( $state->{root}, ['zfs set quota=1T tank/vm-disks/runner'], 'a new quota sets the quota, and nothing else' );
};

subtest 'it refuses a hypervisor that cannot hold the account' => sub {
    my $state = fresh_state();

    $state->{sudo} = 'Sudo version 1.9.9';
    like( exception { run_tool( $state, @create ) }, qr/older[ ]than[ ]1[.]9[.]10/, 'a sudo that cannot read the patterns of the grant' );
    $state->{sudo} = 'Sudo version 1.9.15p5';

    delete $state->{files}{'/usr/libexec/virtiofs-better'};
    like( exception { run_tool( $state, @create ) }, qr/will[ ]not[ ]be[ ]able[ ]to[ ]install[ ]it/, 'a hypervisor without virtiofs-better, which the account cannot install' );
    $state->{files}{'/usr/libexec/virtiofs-better'} = q{};

    $state->{fstype}{'/bogus/vm-disks'} = 'xfs';
    my $error = exception { run_tool( $state, @create ) };
    like( $error, qr/only[ ]on[ ]ZFS/, 'a pool that is not on ZFS' );
    like( $error, qr/xfs_quota/,       'with the advice of note_pool_quota for that filesystem' );
    $state->{fstype}{'/bogus/vm-disks'} = 'zfs';

    $state->{datasets}{'tank/vm-disks'}{mountpoint} = '/bogus';
    like( exception { run_tool( $state, @create ) }, qr/would[ ]not[ ]mount[ ]at/, 'a parent directory that is not where a dataset is mounted' );
    $state->{datasets}{'tank/vm-disks'}{mountpoint} = '/bogus/vm-disks';

    $state->{pools}{runner_disks} = { path => '/bogus/elsewhere' };
    like( exception { run_tool( $state, @create ) }, qr/already[ ]has[ ]a[ ]pool[ ]runner_disks[ ]at/, 'a pool name libvirt already has somewhere else' );
    is( $state->{pools}{runner_disks}{path}, '/bogus/elsewhere', 'and leaves that pool alone' );
};

subtest 'a grant visudo refuses is not installed' => sub {
    my $state = fresh_state();
    $state->{visudo_refuses} = 1;

    like( exception { run_tool( $state, @create ) }, qr/visudo[ ]refused/, 'it dies' );
    ok( !exists $state->{files}{'/etc/sudoers.d/90-trog-runner-runner'}, 'with nothing in sudoers.d' );
    ok( !exists $state->{files}{'/tmp/staged'},                          'and the staged copy removed' );
};

subtest 'remove takes it all away, and not the disks of guests' => sub {
    my $state = fresh_state();
    run_tool( $state, @create );

    push @{ $state->{pools}{runner_disks}{volumes} }, 'vm.test.test.qcow2';
    like( exception { run_tool( $state, @remove ) }, qr/still[ ]holds[ ]vm[.]test[.]test[.]qcow2/, 'a pool with a volume in it stops the removal' );
    ok( exists $state->{datasets}{'tank/vm-disks/runner'}, 'and the dataset is still there' );

    $state->{pools}{runner_disks}{volumes} = [];
    $state->{dirs}{'/bogus/vm-disks/runner'} = '/bogus/vm-disks/runner/left-behind.qcow2';
    like( exception { run_tool( $state, @remove ) }, qr/still[ ]holds[ ]\/bogus\/vm-disks\/runner\/left-behind/, 'so does a file in the directory that the pool does not list' );
    ok( exists $state->{datasets}{'tank/vm-disks/runner'}, 'and the dataset is still there' );

    # The pool undefined by hand leaves the disks in the dataset.
    my $pool = delete $state->{pools}{runner_disks};
    like( exception { run_tool( $state, @remove ) }, qr/still[ ]holds/, 'with no pool to ask, the files in the directory still stop the removal' );
    ok( exists $state->{datasets}{'tank/vm-disks/runner'}, 'and the dataset is still there' );
    $state->{pools}{runner_disks} = $pool;

    delete $state->{dirs}{'/bogus/vm-disks/runner'};
    my ($rc) = run_tool( $state, @remove );
    is( $rc, 0, 'an empty one goes' );
    ok( !exists $state->{files}{'/etc/sudoers.d/90-trog-runner-runner'},     'with the grant' );
    ok( !exists $state->{files}{'/etc/systemd/system/machine-runner.slice'}, 'the slice' );
    ok( !exists $state->{pools}{runner_disks},                               'the pool' );
    ok( !exists $state->{datasets}{'tank/vm-disks/runner'},                  'the dataset' );
    ok( !exists $state->{users}{runner},                                     'and the user' );

    $state->{root} = [];
    run_tool( $state, @remove );
    is_deeply( $state->{root}, [], 'and a second removal has nothing to do' );
};

done_testing();
