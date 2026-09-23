#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/preflight.t - bin/preflight: what it checks, and what it tells you to do about it

=cut

use Test::More;
use Capture::Tiny    qw{capture_stdout};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use List::Util();
use File::Slurper();
use File::Slurper::Temp();
use FindBin;
use FindBin::libs;
use Provisioner::Cookbook();

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Trog::HV();

# Loaded so Test::MockModule has a package to attach to: Trog::HV requires its
# backend lazily, and it is named only as a string below.
use Trog::HV::Libvirt();
use Trog::HV::OpenStack();
use Trog::HV::Linode();    ## no critic (ProhibitUnusedImports)

# These patterns quotemeta a literal on purpose: a fixture string this test
# wrote itself, full of dots and slashes that would otherwise need escaping one
# at a time.  The policy is about production code, where a \Q...\E round
# anything but an interpolated value is usually an accident.
## no critic (RegularExpressions::PreventUselessMetacharacterEscapes)

my $script = "$FindBin::Bin/../bin/preflight";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# Captured at the file descriptor, which is what Capture::Tiny does, rather than
# by localising the glob.  Some checks run a command, and IPC::Run3 saves and
# restores the real STDOUT around one -- an in-memory handle in its place is not
# something it can hand back, and everything printed after the first such check
# goes missing rather than failing.
sub quietly {
    my ($code) = @_;

    my ( $said, @result ) = capture_stdout { $code->() };
    return wantarray ? ( $result[0], $said ) : $result[0];
}

# Stands in for the api a cloud hypervisor talks through.
{

    package Test::PreflightCloud;

    sub new { my ( $c, %a ) = @_; return bless {%a}, $c }
    sub auth     ($self) { return $self }
    sub services ($self) { return @{ $self->{services} } }

    sub look_by_id_or_name {
        my ( $self, $kind, $name ) = @_;
        die "Cannot find '$kind' for id/name '$name'\n" unless List::Util::any { $_ eq $name } @{ $self->{$kind} // [] };
        return { name => $name };
    }

    # Glance filters on the os_ properties that image_for_distro asks by.
    sub list_images {
        my ( $self, %query ) = @_;
        return grep {
            my $image = $_;
            List::Util::all { ( $image->{$_} // q{} ) eq $query{$_} } keys %query
        } @{ $self->{images} // [] };
    }
}

sub cloud_hv {
    my (%opts) = @_;

    my $api = Test::PreflightCloud->new(
        services => [qw{compute image network volumev3}],
        flavors  => ['m1.medium'],
        networks => ['internal'],
        images   => [ { id => 'img-noble', os_distro => 'ubuntu', os_version => '24.04', status => 'active' } ],
        %{ $opts{api} // {} },
    );

    Trog::HV->forget();
    my $hv = Trog::HV->new( cloud => 'testcloud', network => 'internal', %{ $opts{hv} // {} } );

    my $mock = Test::MockModule->new('Trog::HV::OpenStack');
    $mock->redefine( api => sub { $api } );

    return ( $hv, $mock );
}

subtest 'a cloud is checked for what a cloud can be wrong about' => sub {
    my ( $hv, $mock ) = cloud_hv();

    my ($ok) = quietly( sub { $hv->check_reachable } );
    ok $ok->{ok}, 'a credential that authenticates and a catalog with the three services';

    ($ok) = quietly( sub { $hv->check_cloud_resources } );
    ok $ok->{ok}, 'a network the cloud has, the flavors the guests name, and an image for the distro in use';
    like $ok->{what}, qr/from[ ]img-noble/, 'naming the image the distro recipe gets';

    # Getting one of these wrong otherwise fails a provision minutes in, with an
    # error from the API rather than from us.
    my $in_config = Test::MockModule->new('Trog::HV');
    $in_config->redefine( globals_in_use => sub { return ('m1.nope') } );
    my ($failed) = quietly( sub { $hv->check_cloud_resources } );
    ok !$failed->{ok}, 'and it notices a flavor a guest names that the cloud has not got';
    like $failed->{what}, qr/flavor[ ]'m1\.nope'/, 'naming the flavor';
    $in_config->unmock('globals_in_use');

    my ( $bare, $bare_mock ) = cloud_hv( api => { images => [] } );
    ($failed) = quietly( sub { $bare->check_cloud_resources } );
    ok !$failed->{ok}, 'and a cloud with no image for the distro';
    like $failed->{fix}, qr/os_distro=ubuntu[ ]and[ ]os_version=24[.]04/, 'saying which properties an image needs';

    my ( $thin, $thin_mock ) = cloud_hv( api => { services => [qw{compute volumev3}] } );
    ($failed) = quietly( sub { $thin->check_reachable } );
    ok !$failed->{ok}, 'a catalog without Glance or Neutron cannot build a guest';
    like $failed->{what}, qr/image,[ ]network/, 'and it says which are missing';
};

subtest 'a cloud runs out of quota, not of hardware' => sub {
    my ( $hv, $mock ) = cloud_hv();

    my $capacity = { guests => 4, memory_free => 8192, memory_mb => 51200, memory_committed => 32768, cpus => 40, cpus_committed => 20, cpus_free => 19, disk_free => 1024 };
    $mock->redefine( capacity   => sub { return $capacity } );
    $mock->redefine( max_guests => sub { 10 } );

    my ($ok) = quietly( sub { $hv->check_cloud_quota } );
    ok $ok->{ok}, 'room for one more';
    like $ok->{what}, qr{4/10[ ]instances}, 'and it says how much room';

    $mock->redefine( capacity => sub { return { %$capacity, memory_free => 0, cpus_free => 0 } } );
    my ($failed) = quietly( sub { $hv->check_cloud_quota } );
    ok !$failed->{ok}, 'and none is a failure';
    like $failed->{what}, qr/memory/, 'naming what ran out';

    $mock->redefine( capacity => sub { return { %$capacity, guests => 10 } } );
    ($failed) = quietly( sub { $hv->check_cloud_quota } );
    ok !$failed->{ok}, 'so is being at the instance cap';
    like $failed->{what}, qr/instances/, 'which is said as such';

    Trog::HV->forget();
};

subtest 'libvirt packs its version into one integer' => sub {
    is( Trog::HV::Libvirt::_version_string(10000000), '10.0.0', 'major only' );     ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
    is( Trog::HV::Libvirt::_version_string(9004000),  '9.4.0',  'and minor' );      ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
    is( Trog::HV::Libvirt::_version_string(8000012),  '8.0.12', 'and release' );    ## no critic (Subroutines::ProtectPrivateSubs) -- the private sub is what this tests
};

subtest 'Sys::Virt has to be in step with the hypervisor' => sub {

    # Sys::Virt binds the API of the libvirt release it was built against, so a
    # mismatch shows up as a missing constant rather than as a version error.
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    my $sv = Test::MockModule->new('Sys::Virt');

    $hv->redefine( vmm                 => sub { bless {}, 'Sys::Virt' } );
    $sv->redefine( get_library_version => sub { 10000000 } );

    $sv->redefine( VERSION => sub { '10.0.0' } );
    my ($result) = quietly( sub { Trog::HV->new()->check_sys_virt_in_step } );
    ok( $result->{ok}, 'the same release passes' );
    like( $result->{what}, qr/Sys::Virt[ ]10\.0\.0[ ]matches[ ]libvirt[ ]10\.0\.0/, 'saying both versions' );

    # A release apart in either direction is out of step.
    foreach my $version (qw{9.4.0 11.0.0}) {
        $sv->redefine( VERSION => sub { $version } );
        ($result) = quietly( sub { Trog::HV->new()->check_sys_virt_in_step } );
        ok( !$result->{ok}, "$version against 10.0.0 fails" );
        like( $result->{fix}, qr/bring[ ]this[ ]machine[ ]to[ ]10\.0\.0/, 'and says which way to move' );
    }

    # A patch release apart is not: lockstep is on major.minor.
    $sv->redefine( get_library_version => sub { 10000004 } );
    $sv->redefine( VERSION             => sub { '10.0.0' } );
    ($result) = quietly( sub { Trog::HV->new()->check_sys_virt_in_step } );
    ok( $result->{ok}, '10.0.0 against 10.0.4 is in step' );
};

subtest 'a hypervisor that will not answer is reported, not thrown' => sub {
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( vmm => sub { die "no route to host\n" } );

    my ($result) = quietly( sub { Trog::HV->new()->check_libvirt } );
    ok( !$result->{ok}, 'libvirt check fails' );

    ($result) = quietly( sub { Trog::HV->new()->check_sys_virt_in_step } );
    ok( !$result->{ok}, 'and so does the version check, rather than dying on the way' );
    like( $result->{fix}, qr/Fix[ ]that[ ]first/, 'pointing at the one above it' );
};

subtest 'passwordless sudo is the one that would hang the run' => sub {
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');

    $hv->redefine( run_cmd => sub { 0 } );
    my ($result) = quietly( sub { Trog::HV->new()->check_passwordless_sudo } );
    ok( $result->{ok}, 'sudo -n succeeding passes' );

    $hv->redefine( run_cmd => sub { 1 } );
    ($result) = quietly( sub { Trog::HV->new()->check_passwordless_sudo } );
    ok( !$result->{ok}, 'and failing does not' );
    like( $result->{fix}, qr/NOPASSWD/,                        'the guidance is the sudoers line' );
    like( $result->{fix}, qr/hangs[ ]rather[ ]than[ ]failing/, 'and says why it matters more than it looks' );
    like( $result->{fix}, qr/take[ ]it[ ]away[ ]again/,        'and that it is a real grant of root' );
};

subtest 'rsync is the one thing both ends have to have' => sub {
    my $hv    = Test::MockModule->new('Trog::HV::Libvirt');
    my $which = Test::MockModule->new('File::Which');

    $hv->redefine( is_local => sub { 0 } );
    $hv->redefine( describe => sub { 'someadmin@hv.test' } );

    # Both there.
    $hv->redefine( run_cmd => sub { 0 } );
    $which->redefine( which => sub { '/usr/bin/rsync' } );
    my ($result) = quietly( sub { Trog::HV->new()->check_rsync } );
    ok( $result->{ok}, 'rsync at both ends passes' );

    # Missing on the hypervisor.
    $hv->redefine( run_cmd => sub { 1 } );
    ($result) = quietly( sub { Trog::HV->new()->check_rsync } );
    ok( !$result->{ok}, 'missing on the hypervisor fails' );
    like( $result->{what}, qr/someadmin\@hv[.]test/,  'naming the end that has not got it' );
    like( $result->{fix},  qr/apt[ ]install[ ]rsync/, 'and how to fix it' );

    # Missing here, which is just as fatal and much easier to overlook: this is
    # the machine that runs the rsync, not the one it talks to.
    $hv->redefine( run_cmd => sub { 0 } );
    $which->redefine( which => sub { undef } );
    ($result) = quietly( sub { Trog::HV->new()->check_rsync } );
    ok( !$result->{ok}, 'missing here fails too' );
    like( $result->{what}, qr/this[ ]machine/, 'naming this end' );

    # A local hypervisor is one machine, and is not asked twice about it.
    $hv->redefine( is_local => sub { 1 } );
    $hv->redefine( run_cmd  => sub { die 'a local hypervisor should not be asked over ssh' } );
    $which->redefine( which => sub { '/usr/bin/rsync' } );
    ($result) = quietly( sub { Trog::HV->new()->check_rsync } );
    ok( $result->{ok}, 'and a local hypervisor is answered for by this machine' );
};

# Every other check can pass while this one cannot, and then the run dies
# minutes in on a curl, naming the image URL rather than the permissions that
# refused it.  That is how a hypervisor whose pool had just been moved onto a
# fresh dataset reported itself ready and then could not build anything.
subtest 'a storage pool nothing can write to is a hypervisor nothing can be built on' => sub {
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');

    $hv->redefine( pool_path => sub { '/bogus/pool' } );
    $hv->redefine( describe  => sub { 'someadmin@hv.test' } );

    $hv->redefine( run_cmd => sub { 0 } );
    my ($result) = quietly( sub { Trog::HV->new()->check_pool_writable } );
    ok( $result->{ok}, 'a pool that takes a write passes' );
    like( $result->{what}, qr{/bogus/pool}, 'naming the pool it wrote into' );

    $hv->redefine( run_cmd => sub { 1 } );
    ($result) = quietly( sub { Trog::HV->new()->check_pool_writable } );
    ok( !$result->{ok}, 'and one that refuses the write does not' );
    like( $result->{what}, qr/someadmin\@hv[.]test/, 'naming the hypervisor it asked' );
    like( $result->{fix},  qr/chown/,                'the guidance is the ownership' );

    # Both halves of the fix, because the filesystem one alone does not survive:
    # libvirt takes a built pool's ownership from the pool definition.
    like( $result->{fix}, qr/pool-dumpxml/, 'and says the pool definition has to agree' );

    # And why it is not simply sudo'd, which is the obvious wrong fix: base_image
    # deliberately does not either.
    like( $result->{fix}, qr/sudo[ ]here[ ]would/, 'and why sudo is not the answer' );

    # Not being able to find the pool at all is a different answer to not being
    # able to write to it, and wants different guidance.
    $hv->redefine( pool_path => sub { undef } );
    ($result) = quietly( sub { Trog::HV->new()->check_pool_writable } );
    ok( !$result->{ok}, 'a pool that cannot be located fails too' );
    like( $result->{fix}, qr/pool-list/, 'and says how to find what pools there are' );
};

subtest 'a guest has to have an address of ours to fetch from' => sub {
    my $hv    = Test::MockModule->new('Trog::HV::Libvirt');
    my $local = Test::MockModule->new('Trog::Local');

    $hv->redefine( virbr_ip => sub { '192.168.122.1' } );

    $local->redefine( transfer_ip => sub { '192.168.122.251' } );
    my ($result) = quietly( sub { Trog::HV->new()->check_transfer_ip } );
    ok( $result->{ok}, 'an address a guest can route to passes' );
    like( $result->{what}, qr/192[.]168[.]122[.]251/, 'and says which one, since nothing else names it' );

    # A workstation on none of the hypervisor's networks. The guest's very first
    # target fetches from here, so this is the whole run failing later.
    $local->redefine( transfer_ip => sub { undef } );
    ($result) = quietly( sub { Trog::HV->new()->check_transfer_ip } );
    ok( !$result->{ok}, 'no route to the guest network fails' );
    like( $result->{fix}, qr/transfer_ip/, 'and points at the setting that overrides it' );
    like( $result->{fix}, qr/_global/,     'in the block it goes in' );

    # Reported, not thrown: a hypervisor that will not answer about its bridge
    # is one more line in the list rather than the end of the run.
    $hv->redefine( virbr_ip => sub { die "no brctl\n" } );
    ($result) = quietly( sub { Trog::HV->new()->check_transfer_ip } );
    ok( !$result->{ok}, 'a hypervisor that cannot say where its guests live fails' );
};

# A directory the operator owns and this tool only reads.  It is fetched off
# this machine during the build, so an absent one fails a recipe's target part
# way through -- and rsync's error for it names neither the recipe nor the
# domain.
subtest 'a directory a recipe fetches has to be on this machine' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $hv  = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( ssh_host => sub { 'hv.test' } );

    my $present = "$dir/dotfiles";
    mkdir $present;

    my $write = sub {
        File::Slurper::Temp::write_text( "$dir/recipes.yaml", $_[0] );
        Provisioner::Cookbook->forget();
        return;
    };

    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    # skel is said once in _base for the whole fleet, so this is the usual shape.
    $write->("---\n_base:\n    adminconfig:\n        skel: \"$present\"\none.test:\n    adminconfig:\n");
    my ($result) = quietly( sub { Trog::HV->new()->check_fetch_sources } );
    ok( $result->{ok}, 'a directory that is there passes' );

    $write->("---\n_base:\n    adminconfig:\n        skel: \"$dir/gone\"\none.test:\n    adminconfig:\ntwo.test:\n    openvpnclient:\n        cert_dir: $dir/alsogone\n");
    ($result) = quietly( sub { Trog::HV->new()->check_fetch_sources } );
    ok( !$result->{ok}, 'one that is not fails' );
    like( $result->{what}, qr/\b2[ ]fetched[ ]directories/,       'counting the paths rather than the domains that wanted them' );
    like( $result->{fix},  qr{\Q$dir/gone\E[ ]\Q(adminconfig)\E}, 'naming the path and the recipe that asked' );
    like( $result->{fix},  qr{alsogone[ ]\Q(openvpnclient)\E},    'for each of them' );
    like( $result->{fix},  qr{rsync[ ]-a[ ]hv[.]test:},           'and how to bring one over from the hypervisor' );

    # Nothing to check is not a failure: a fleet may run no recipe that fetches
    # a directory of the operator's at all.
    $write->("---\none.test:\n    ntp:\n");
    ($result) = quietly( sub { Trog::HV->new()->check_fetch_sources } );
    ok( $result->{ok}, 'and a configuration that fetches nothing passes' );
};

subtest 'the configuration it copies from has to be there' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    my ($result) = quietly( sub { Trog::HV->new()->check_config } );
    ok( !$result->{ok}, 'an empty directory fails' );
    like( $result->{what}, qr/recipes\.yaml,[ ]admin_authorized_keys/, 'naming what is missing' );
    like( $result->{fix},  qr/ssh-import-id/,                          'and how to seed the keys' );

    foreach my $file (qw{recipes.yaml admin_authorized_keys}) {
        open( my $fh, '>', "$dir/$file" ) or die $!;
        close($fh)                        or die "Could not close $dir/$file: $!";
    }

    # Nobody authorized is not a configuration a guest can be built from, and an
    # empty file would otherwise pass here and stop bin/new_config instead --
    # one round trip later, which is the thing this check exists to save.
    ($result) = quietly( sub { Trog::HV->new()->check_config } );
    ok( !$result->{ok}, 'a key file with nothing in it is no better than none' );
    like( $result->{what}, qr/admin_authorized_keys/, 'and that is the one it names' );

    File::Slurper::Temp::write_text( "$dir/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAsomebodyskey somebody\n" );

    # The files being there says nothing about whether they say who
    # administers a guest, which bin/new_config reads for the first domain it
    # generates.
    ($result) = quietly( sub { Trog::HV->new()->check_config } );
    ok( !$result->{ok}, 'an empty recipes.yaml is a configuration with no settings in it' );
    like( $result->{what}, qr/settings[ ]every[ ]guest/, 'which it says' );
    like( $result->{fix},  qr/ipmap_to_globals/,         'and how an older installation brings them across' );

    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "---\n_base:\n  _global:\n    basedir: /bogus\n    admin_user: someadmin\n    admin_gecos: Some Admin\n    admin_email: someadmin\@test.test\n    gateway: 192.0.2.254\n    resolvers: [192.0.2.254]\n" );
    Provisioner::Cookbook->forget();

    ($result) = quietly( sub { Trog::HV->new()->check_config } );
    ok( $result->{ok}, 'and passes once they are there' );
};

# Saying the keys are missing is check_config's; offering to fetch them is not.
# A verdict is a thing to print, and this is a thing to ask -- so it lives apart,
# and the asking has to be impossible when there is nobody to answer.
subtest 'the missing keys can be seeded, but only at a terminal' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;
    my $path = "$dir/admin_authorized_keys";

    my $local_mock = Test::MockModule->new('Trog::Local');
    my $prompt     = Test::MockModule->new('IO::Prompter');
    my $machine    = Test::MockModule->new('Trog::Machine');

    my ( @ran, @answers );
    $machine->redefine( run_cmd => sub { my ( $self, @argv ) = @_; push @ran, join( ' ', @argv ); return 0 } );
    $prompt->redefine( prompt => sub { return shift @answers } );

    # The unattended run the provisioning workflow makes.  A question there has
    # nowhere to be answered from, so it would block rather than fail -- which is
    # worse than the check simply reporting the file is missing.
    $local_mock->redefine( interactive => sub { 0 } );
    @answers = qw{gh somebody};
    my ($rc) = quietly( sub { Trog::Bin::Preflight::seed_admin_keys() } );
    is( $rc, 0, 'with nobody there it does not ask' );
    is_deeply( \@ran, [], 'and runs nothing' );

    $local_mock->redefine( interactive => sub { 1 } );
    @answers = qw{gh somebody};
    ($rc) = quietly( sub { Trog::Bin::Preflight::seed_admin_keys() } );
    is( $rc, 1, 'asked and answered, it seeds' );
    is_deeply( \@ran, ["ssh-import-id -o $path gh:somebody"], 'from the identity the answers named' );

    # Neither gh nor lp is how somebody says no, and ssh-import-id knows no
    # other service to be handed.
    @ran     = ();
    @answers = qw{nope somebody};
    ($rc) = quietly( sub { Trog::Bin::Preflight::seed_admin_keys() } );
    is( $rc, 0, 'an answer it cannot import from is a decline, not an error' );
    is_deeply( \@ran, [], 'running nothing' );

    # check_config fails an empty file as it fails a missing one, so the offer
    # has to be made for both.
    @ran = ();
    open( my $empty, '>', $path ) or die "Could not write $path: $!";
    close($empty)                 or die "Could not close $path: $!";
    @answers = qw{gh somebody};
    ($rc) = quietly( sub { Trog::Bin::Preflight::seed_admin_keys() } );
    is( $rc, 1, 'an empty file is offered a seed' );
    is_deeply( \@ran, ["ssh-import-id -o $path gh:somebody"], 'into that file' );

    @ran = ();
    open( my $fh, '>', $path )                                                or die "Could not write $path: $!";
    print {$fh} "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAsomebodyskey somebody\n" or die "Could not write $path: $!";
    close($fh)                                                                or die "Could not close $path: $!";

    @answers = qw{gh somebody};
    ($rc) = quietly( sub { Trog::Bin::Preflight::seed_admin_keys() } );
    is( $rc, 0, 'and a file already there is never offered for' );
    is_deeply( \@ran, [], 'nor anything run against it' );
};

subtest 'every check reports rather than dying, so one run gets the whole list' => sub {

    # Being told about the sudo, and then a fix later about the missing
    # xorriso, is two round trips where one would do.
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( is_local  => sub { 1 } );
    $hv->redefine( run_cmd   => sub { 1 } );              # no passwordless sudo
    $hv->redefine( iso_maker => sub { die "none\n" } );
    $hv->redefine( vmm       => sub { die "no\n" } );

    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    my ( $rc, $out ) = quietly( sub { Trog::Bin::Preflight::main() } );
    is( $rc, 1, 'exits non-zero' );

    like( $out, qr/sudo/,                          'the sudo failure is in there' );
    like( $out, qr/ISO[ ]builder/,                 'and the ISO builder' );
    like( $out, qr/libvirt/,                       'and libvirt' );
    like( $out, qr/Missing[ ]or[ ]empty[ ]in/,     'and the configuration' );
    like( $out, qr/7[ ]things[ ]to[ ]fix[ ]first/, 'counted, all in one run' );
};

subtest '--credentials reads the passwords before any check asks for one' => sub {

    # A Linode token lives in the secret store, so a check that asks Linode
    # needs its passphrase, and a run with nobody at the terminal can only give
    # it on standard input.
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( is_local  => sub { 1 } );
    $hv->redefine( run_cmd   => sub { 1 } );
    $hv->redefine( iso_maker => sub { die "none\n" } );
    $hv->redefine( vmm       => sub { die "no\n" } );

    my $loaded      = 0;
    my $credentials = Test::MockModule->new('Trog::Credentials');
    $credentials->redefine( load => sub { $loaded++; return 1 } );

    local $ENV{TROG_PROVISIONER_CONFIG} = tempdir( CLEANUP => 1 );

    quietly( sub { Trog::Bin::Preflight::main() } );
    is( $loaded, 0, 'without it, standard input is left alone' );

    quietly( sub { Trog::Bin::Preflight::main('--credentials') } );
    is( $loaded, 1, 'with it, the passwords are read, once' );
};

subtest 'which hypervisors need a port forwarded to us, and which do not' => sub {
    my $local = Test::MockModule->new('Trog::Local');
    $local->redefine( sshd_port     => sub { 22 } );
    $local->redefine( holds_address => sub { my ( undef, $address ) = @_; return $address eq '192.0.2.10' ? 1 : 0 } );
    my $answered = 0;
    $local->redefine( answers_on => sub { return $answered } );

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( globals => sub { return {} } );

    # A guest on a machine of ours shares a network with us, and the routing
    # table answers when the configuration is generated.
    my $libvirt = Trog::HV::Libvirt->build( uri => 'qemu:///system' );
    my $result  = $libvirt->check_transfer_route;
    ok $result->{ok}, 'a machine of ours needs nothing forwarded';
    like $result->{what}, qr/across[ ]our[ ]own[ ]network/, 'because its guests are on a network we share';

    # A guest a service addresses is not, so it reaches us from outside.
    my $cloud = Trog::HV::OpenStack->build( cloud => 'testcloud' );
    $result = $cloud->check_transfer_route;
    ok !$result->{ok}, 'a cloud with nothing named cannot be reached at all';
    like $result->{fix}, qr/transfer_ip\s+=/, 'and is told which settings to write';

    $cloud->{transfer_ip} = '10.0.0.5';
    $result = $cloud->check_transfer_route;
    ok !$result->{ok}, 'nor one told to use an address nothing on the internet routes to';
    like $result->{what}, qr/private[ ]address/, 'which it says';

    $cloud->{transfer_ip} = '192.0.2.10';
    $result = $cloud->check_transfer_route;
    ok $result->{ok}, 'an address of this machine is reachable as it is';
    like $result->{what}, qr/192[.]0[.]2[.]10:22/, 'at the port this machine listens on';

    $cloud->{transfer_ip}   = '198.51.100.7';
    $cloud->{transfer_port} = 2222;
    $result                 = $cloud->check_transfer_route;
    ok !$result->{ok}, 'an address that is not ours and does not answer is a failure';
    like $result->{fix}, qr/forward[ ]2222[ ]to[ ]the[ ]sshd[ ]here/,  'saying what has to forward what';
    like $result->{fix}, qr/does[ ]not[ ]answer[ ]its[ ]own[ ]public/, 'and that a gateway may be hiding a forward that works';

    # The same address, once something answers on it.
    $answered = 1;
    $result   = $cloud->check_transfer_route;
    ok $result->{ok}, 'and one that answers is taken as forwarded here';
    like $result->{what}, qr/something[ ]forwards[ ]it[ ]here/, 'which is what answering means';
};

subtest 'a distro pinned to an image that has moved on is worth saying so about' => sub {
    my $ubuntu = Test::MockModule->new('Provisioner::Recipe::ubuntu');

    # Current, so there is nothing to report.
    $ubuntu->redefine( current_release => sub { return 'noble' } );
    is_deeply( Trog::HV->new()->note_stale_image, { ok => 1 }, 'a pin that is current says nothing' );

    # A release behind.
    $ubuntu->redefine( current_release => sub { return 'plucky' } );
    my $note = Trog::HV->new()->note_stale_image;
    ok( !$note->{ok}, 'a pin that has fallen behind is reported' );
    like( $note->{fix}, qr/noble/,  'naming what it builds on' );
    like( $note->{fix}, qr/plucky/, 'and what it would build on now' );

    # A mirror that will not answer is not a reason to hold up a provision, so
    # a distribution with no answer gets no note rather than a wrong one.
    $ubuntu->redefine( current_release => sub { return undef } );
    is_deeply( Trog::HV->new()->note_stale_image, { ok => 1 }, 'and a distribution that could not be asked says nothing either' );
};

subtest 'a fleet with no package mirror is told what that costs' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my $write = sub {
        File::Slurper::Temp::write_text( "$dir/recipes.yaml", $_[0] );
        Provisioner::Cookbook->forget();
        return Trog::HV->new()->note_apt_mirror;
    };

    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    # A fresh installation has no domains, and so nothing to say this about.
    is_deeply( $write->("---\n_base:\n    nosnap:\n"), { ok => 1 }, 'nothing configured yet, nothing said' );

    my $note = $write->("---\nweb.example.net:\n    nginx:\n");
    ok( !$note->{ok}, 'domains but no mirror is worth saying' );
    like( $note->{fix}, qr/bin\/new_guest[ ]--hostname[ ]aptmirror\.example\.net[ ]aptmirror/, 'naming the command, under the parent the fleet already uses' );    ## no critic (RegularExpressions::ProhibitComplexRegexes)

    # The more annoying of the two: the work is done and nothing is using it.
    $note = $write->("---\nweb.example.net:\n    nginx:\naptmirror.example.net:\n    aptmirror:\n        releases: [noble]\n");
    ok( !$note->{ok}, 'a mirror nobody points at is worth saying louder' );
    like( $note->{what}, qr/aptmirror\.example\.net[ ]mirrors[ ]the[ ]archive/, 'naming the guest that is doing the mirroring' );
    like( $note->{fix},  qr/mirror:[ ]aptmirror\.example\.net/,                 'and the line that would use it' );

    # Either spelling counts as pointing at one.
    is_deeply( $write->("---\n_base:\n    _global:\n        mirror: aptmirror.example.net\nweb.example.net:\n    nginx:\n"), { ok => 1 }, 'a mirror in _base _global is enough' );
    is_deeply( $write->("---\nweb.example.net:\n    ubuntu:\n        mirror: http://m.test/ubuntu\n"),                       { ok => 1 }, 'as is one in a domain distro block' );
};

subtest 'a fleet with nothing keeping its logs is told so, once there is a sink' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    # No leftovers on the hypervisor for most of this: the upgrade case has its
    # own subtest below, and it short-circuits everything else when it fires.
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( list_dir => sub { return () } );
    $hv->redefine( describe => sub { return 'the hypervisor' } );

    my $write = sub {
        File::Slurper::Temp::write_text( "$dir/recipes.yaml", $_[0] );
        Provisioner::Cookbook->forget();
        return Trog::HV->new()->note_log_destination;
    };

    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    # Logging is opt-in, so a fleet that has not asked for it has nothing said
    # about it -- unlike a mirror, which every guest pays for not having.
    is_deeply( $write->("---\nweb.example.net:\n    nginx:\n"), { ok => 1 }, 'no collector and no shipper says nothing' );

    my $note = $write->("---\nlogs.example.net:\n    logcollector:\n");
    ok( !$note->{ok}, 'a sink with nothing shipping to it is worth saying' );
    like( $note->{what}, qr/logs\.example\.net[ ]collects[ ]logs/, 'naming the guest doing the collecting' );
    like( $note->{fix},  qr/host:[ ]logs\.example\.net/,           'and the line that would use it' );

    is_deeply(
        $write->("---\n_base:\n    logshipper:\n        host: logs.example.net\nlogs.example.net:\n    logcollector:\n"),
        { ok => 1 }, 'and nothing once the fleet points at it'
    );
};

subtest 'the drop-ins provisioning used to write are worth pointing at' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "---\nweb.example.net:\n    nginx:\nold.example.net:\n    nginx:\n" );
    Provisioner::Cookbook->forget();

    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( describe => sub { return 'the hypervisor' } );

    # Only the per-domain ones this tool wrote.  20-ufw.conf and 50-default.conf
    # are the distribution's, and a 10- file for a domain nobody has configured
    # is somebody else's business.
    $hv->redefine(
        list_dir => sub {
            return qw{10-web.example.net.conf 10-old.example.net.conf 10-notours.example.conf 20-ufw.conf 50-default.conf};
        }
    );

    my $note = Trog::HV->new()->note_log_destination;
    ok( !$note->{ok}, 'leftovers are worth a note' );
    like( $note->{what}, qr/\A2[ ]rsyslog[ ]drop-ins/, 'counting only the ones written for a domain we know about' );
    unlike( $note->{fix}, qr/notours|20-ufw|50-default/, 'and leaving everything else on that machine alone' );

    # Comma-joined with no spaces, or the brace expansion it prints cannot be
    # pasted into a shell.
    like( $note->{fix}, qr/\Q{old.example.net,web.example.net}\E/, 'the removal command is one that would actually run' );
};

subtest 'a secret written into the configuration in the clear is worth saying' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/recipes.d";
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    my $secret = 'hunter2-in-the-clear';
    File::Slurper::Temp::write_text(
        "$dir/recipes.yaml",
        "---\nweb.test.test:\n" . "    mail:\n        names:\n            someuser:\n                password: $secret\n                gecos: A\n" . "    pdns:\n        api_key: secret:dns/pdns/password\n" . "    backup:\n        key_file: backup.rsa\n"
    );

    my $note = Trog::HV->new()->note_plaintext_secrets;
    ok( !$note->{ok}, 'a literal password is reported' );
    like( $note->{at} // $note->{fix}, qr/mail\.names\.someuser\.password/, 'naming the field' );

    # Never the value.  A note that printed a password to say a password was
    # printed would be its own answer.
    unlike( $note->{fix},  qr/\Q$secret\E/, 'and never the secret itself' );
    unlike( $note->{what}, qr/\Q$secret\E/, 'in either half of it' );

    # Already a reference: the store holds it, which is the whole point.
    unlike( $note->{fix}, qr/api_key/, 'a secret: reference is not complained about' );

    # key_file holds a filename.  Telling somebody to put "backup.rsa" in the
    # store would be advice about nothing.
    unlike( $note->{fix}, qr/key_file/, 'and neither is a field naming a file' );
};

subtest 'a pasted private key is found wherever it was written' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/recipes.d";
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    # Not under a field named for a secret, so the name rule does not see it.
    # This is how a key pasted into the wrong field gets found at all.
    File::Slurper::Temp::write_text(
        "$dir/recipes.d/bot.test.test.yaml",
        "---\nbot.test.test:\n    koan:\n        deploy_material: |\n" . "            -----BEGIN OPENSSH PRIVATE KEY-----\n            b3BlbnNzaC1rZXktdjEA\n            -----END OPENSSH PRIVATE KEY-----\n"
    );

    my $note = Trog::HV->new()->note_plaintext_secrets;
    ok( !$note->{ok}, 'the key is reported' );
    like( $note->{fix}, qr/deploy_material/, 'by where it was written' );
    unlike( $note->{fix}, qr/BEGIN[ ]OPENSSH/, 'and without reproducing it' );
};

subtest 'a configuration that keeps its secrets in the store says nothing' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/recipes.d";
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "---\nweb.test.test:\n    pdns:\n        api_key: secret:t/pdns/password\n" );
    is_deeply( Trog::HV->new()->note_plaintext_secrets, { ok => 1 }, 'nothing to say' );
};

subtest 'every other block in the file is judged too, without building one' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $conf = "$dir/hypervisors.conf";
    File::Slurper::Temp::write_text( $conf, <<'CONF' );
[hv1]
libvirt_uri=qemu:///system

[account]
linode_token=secret:linode/api/password

[cloud]
cloud=openstack

[muddle]
libvirt_uri=qemu:///system
cloud=openstack
CONF

    my $fleet = Trog::Hypervisors->load($conf);

    # The client of a kind of hypervisor this installation does not have is
    # exactly what is not installed, so stand one in.
    my $linode = Test::MockModule->new('Trog::HV::Linode');
    $linode->redefine( client_module => sub { return 'Trog::No::Such::Client' } );

    my ( $failed, $said ) = do {
        my @f;
        my $out = capture_stdout( sub { @f = Trog::Bin::Preflight::rest_of_fleet( $fleet, Trog::HV->candidate( uri => 'qemu:///system', name => 'hv1' ) ) } );
        ( \@f, $out );
    };

    unlike( $said, qr/\[hv1\]/, 'the hypervisor checked in full is not reported twice' );
    like( $said, qr/ok[ ]+\[cloud\][ ]OpenStack::MetaAPI/,                     'a block whose client is installed passes' );
    like( $said, qr/\[cloud\][ ]OpenStack::MetaAPI[ ][\d.]+[ ]is[ ]installed/, 'naming the client it would use, and its version' );
    like( $said, qr/FAILED[ ]\[account\][ ]Trog::No::Such::Client/,            'one whose client is missing fails, named' );
    like( $said, qr/Trog::No::Such::Client[ ]will[ ]not[ ]load[ ]here/,        'saying that client will not load' );
    like( $said, qr/FAILED[ ]\[muddle\][ ]does[ ]not[ ]say[ ]what/,            'and so does one that names two kinds of hypervisor' );

    is( scalar @$failed, 2, 'both are returned as failures, so the run exits non-zero' );
    like( $failed->[0]{fix}, qr/cpanm[ ]Trog::No::Such::Client/,          'the missing client says what installs it' );
    like( $failed->[1]{fix}, qr/it[ ]can[ ]only[ ]be[ ]one[ ]hypervisor/, 'and the muddled block says what is wrong with it' );

    # Judging a block must not authenticate to a cloud, ask Linode anything, or
    # open the secret store to read a token.
    ok( !$fleet->{built}{cloud} && !$fleet->{built}{account}, 'nothing was built to answer' );

    # And a run says all of it, so one preflight covers the whole file.
    my $libvirt = Test::MockModule->new('Trog::HV::Libvirt');
    $libvirt->redefine( is_local => sub { 1 } );
    $libvirt->redefine( run_cmd  => sub { 0 } );
    $libvirt->redefine( vmm      => sub { die "no\n" } );

    my ( $rc, $whole ) = quietly( sub { Trog::Bin::Preflight::main( '--hvconf', $conf, '--hypervisor', 'hv1' ) } );
    is( $rc, 1, 'a fleet with a block nothing can build on fails the run' );
    like( $whole, qr/The[ ]rest[ ]of[ ]the[ ]fleet/,  'the section is printed by a run' );
    like( $whole, qr/cpanm[ ]Trog::No::Such::Client/, 'and the fixes from it are in the list at the end' );
};

subtest 'the client of the hypervisor being checked is the first thing checked' => sub {
    my $hv = Trog::HV->candidate( uri => 'qemu:///system' );
    is( ( $hv->preflight_checks )[0], 'check_client', 'because every check after it fails for a reason that is not theirs' );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( client_module => sub { return 'Trog::No::Such::Client' } );

    my $result = $hv->check_client;
    is( $result->{ok}, 0, 'a hypervisor whose client is not here fails it' );
    like( $result->{fix}, qr/cpanm[ ]Trog::No::Such::Client/, 'saying what to install' );
};

done_testing();
