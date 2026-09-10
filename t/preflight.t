#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/preflight.t - bin/preflight: what it checks, and what it tells you to do about it

=cut

use Test::More;
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use Provisioner::Cookbook();

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Trog::HV();

# Loaded so Test::MockModule has a package to attach to: Trog::HV requires its
# backend lazily, and it is named only as a string below.
use Trog::HV::Libvirt();      ## no critic (ProhibitUnusedImports)
use Trog::HV::OpenStack();    ## no critic (ProhibitUnusedImports)

my $script = "$FindBin::Bin/../bin/preflight";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# Redirected at the file descriptor rather than by localising the glob.  Some
# checks run a command, and IPC::Run3 saves and restores the real STDOUT around
# one -- an in-memory handle in its place is not something it can hand back, and
# everything printed after the first such check goes missing rather than failing.
sub quietly {
    my ($code) = @_;

    my $tmp = File::Temp->new( UNLINK => 1 );
    open( my $saved, '>&', \*STDOUT ) or die "could not save STDOUT: $!";
    open( STDOUT,    '>',  "$tmp" )   or die "could not redirect STDOUT: $!";

    my @result = eval { $code->() };
    my $error  = $@;

    open( STDOUT, '>&', $saved ) or die "could not restore STDOUT: $!";
    die $error if $error;

    return wantarray ? ( $result[0], File::Slurper::read_text("$tmp") ) : $result[0];
}

# Stands in for the api a cloud hypervisor talks through.
{

    package Test::PreflightCloud;

    sub new      { my ( $c, %a ) = @_; return bless {%a}, $c }
    sub auth     { return $_[0] }
    sub services { return @{ $_[0]->{services} } }

    sub look_by_id_or_name {
        my ( $self, $kind, $name ) = @_;
        die "Cannot find '$kind' for id/name '$name'\n" unless grep { $_ eq $name } @{ $self->{$kind} // [] };
        return { name => $name };
    }

    sub image_from_name {
        my ( $self, $name ) = @_;
        return unless grep { $_ eq $name } @{ $self->{images} // [] };
        return { name => $name };
    }
}

sub cloud_hv {
    my (%opts) = @_;

    my $api = Test::PreflightCloud->new(
        services => [qw{compute image network volumev3}],
        flavors  => ['m1.medium'],
        networks => ['internal'],
        images   => ['ubuntu-24.04'],
        %{ $opts{api} // {} },
    );

    Trog::HV->forget();
    my $hv = Trog::HV->new( cloud => 'testcloud', flavor => 'm1.medium', image => 'ubuntu-24.04', network => 'internal', %{ $opts{hv} // {} } );

    my $mock = Test::MockModule->new('Trog::HV::OpenStack');
    $mock->redefine( api => sub { $api } );

    return ( $hv, $mock );
}

subtest 'a cloud is checked for what a cloud can be wrong about' => sub {
    my ( $hv, $mock ) = cloud_hv();

    my ($ok) = quietly( sub { Trog::Bin::Preflight::check_cloud_reachable($hv) } );
    ok $ok->{ok}, 'a credential that authenticates and a catalogue with the three services';

    ($ok) = quietly( sub { Trog::Bin::Preflight::check_cloud_resources($hv) } );
    ok $ok->{ok}, 'a flavor, image and network the cloud has';

    # Getting one of these wrong otherwise fails a provision minutes in, with an
    # error from the API rather than from us.
    my ( $bad, $bad_mock ) = cloud_hv( hv => { flavor => 'm1.nope', image => 'not-an-image' } );
    my ($failed) = quietly( sub { Trog::Bin::Preflight::check_cloud_resources($bad) } );
    ok !$failed->{ok}, 'and it notices when they are not';
    like $failed->{what}, qr/flavor 'm1\.nope'/,    'naming the flavor';
    like $failed->{what}, qr/image 'not-an-image'/, 'and the image';

    my ( $thin, $thin_mock ) = cloud_hv( api => { services => [qw{compute volumev3}] } );
    ($failed) = quietly( sub { Trog::Bin::Preflight::check_cloud_reachable($thin) } );
    ok !$failed->{ok}, 'a catalogue without Glance or Neutron cannot build a guest';
    like $failed->{what}, qr/image, network/, 'and it says which are missing';
};

subtest 'a cloud runs out of quota, not of hardware' => sub {
    my ( $hv, $mock ) = cloud_hv();

    my $capacity = { guests => 4, memory_free => 8192, memory_mb => 51200, memory_committed => 32768, cpus => 40, cpus_committed => 20, cpus_free => 19, disk_free => 1024 };
    $mock->redefine( capacity   => sub { return $capacity } );
    $mock->redefine( max_guests => sub { 10 } );

    my ($ok) = quietly( sub { Trog::Bin::Preflight::check_cloud_quota($hv) } );
    ok $ok->{ok}, 'room for one more';
    like $ok->{what}, qr{4/10 instances}, 'and it says how much room';

    $mock->redefine( capacity => sub { return { %$capacity, memory_free => 0, cpus_free => 0 } } );
    my ($failed) = quietly( sub { Trog::Bin::Preflight::check_cloud_quota($hv) } );
    ok !$failed->{ok}, 'and none is a failure';
    like $failed->{what}, qr/memory/, 'naming what ran out';

    $mock->redefine( capacity => sub { return { %$capacity, guests => 10 } } );
    ($failed) = quietly( sub { Trog::Bin::Preflight::check_cloud_quota($hv) } );
    ok !$failed->{ok}, 'so is being at the instance cap';
    like $failed->{what}, qr/instances/, 'which is said as such';

    Trog::HV->forget();
};

subtest 'libvirt packs its version into one integer' => sub {
    is( Trog::Bin::Preflight::libvirt_version(10000000), '10.0.0', 'major only' );
    is( Trog::Bin::Preflight::libvirt_version(9004000),  '9.4.0',  'and minor' );
    is( Trog::Bin::Preflight::libvirt_version(8000012),  '8.0.12', 'and release' );
};

subtest 'Sys::Virt has to be in step with the hypervisor' => sub {

    # Sys::Virt binds the API of the libvirt release it was built against, so a
    # mismatch shows up as a missing constant rather than as a version error.
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    my $sv = Test::MockModule->new('Sys::Virt');

    $hv->redefine( vmm                 => sub { bless {}, 'Sys::Virt' } );
    $sv->redefine( get_library_version => sub { 10000000 } );

    $sv->redefine( VERSION => sub { '10.0.0' } );
    my ( $result, $out ) = quietly( sub { Trog::Bin::Preflight::check_sys_virt_in_step( Trog::HV->new() ) } );
    ok( $result->{ok}, 'the same release passes' );
    like( $out, qr/Sys::Virt 10\.0\.0 matches libvirt 10\.0\.0/, 'saying both versions' );

    # A release apart in either direction is out of step.
    foreach my $version (qw{9.4.0 11.0.0}) {
        $sv->redefine( VERSION => sub { $version } );
        ( $result, $out ) = quietly( sub { Trog::Bin::Preflight::check_sys_virt_in_step( Trog::HV->new() ) } );
        ok( !$result->{ok}, "$version against 10.0.0 fails" );
        like( $result->{fix}, qr/bring this machine to 10\.0\.0/, 'and says which way to move' );
    }

    # A patch release apart is not: lockstep is on major.minor.
    $sv->redefine( get_library_version => sub { 10000004 } );
    $sv->redefine( VERSION             => sub { '10.0.0' } );
    ($result) = quietly( sub { Trog::Bin::Preflight::check_sys_virt_in_step( Trog::HV->new() ) } );
    ok( $result->{ok}, '10.0.0 against 10.0.4 is in step' );
};

subtest 'a hypervisor that will not answer is reported, not thrown' => sub {
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( vmm => sub { die "no route to host\n" } );

    my ( $result, $out ) = quietly( sub { Trog::Bin::Preflight::check_libvirt( Trog::HV->new() ) } );
    ok( !$result->{ok}, 'libvirt check fails' );

    ($result) = quietly( sub { Trog::Bin::Preflight::check_sys_virt_in_step( Trog::HV->new() ) } );
    ok( !$result->{ok}, 'and so does the version check, rather than dying on the way' );
    like( $result->{fix}, qr/Fix that first/, 'pointing at the one above it' );
};

subtest 'passwordless sudo is the one that would hang the run' => sub {
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');

    $hv->redefine( run_cmd => sub { 0 } );
    my ($result) = quietly( sub { Trog::Bin::Preflight::check_passwordless_sudo( Trog::HV->new() ) } );
    ok( $result->{ok}, 'sudo -n succeeding passes' );

    $hv->redefine( run_cmd => sub { 1 } );
    ($result) = quietly( sub { Trog::Bin::Preflight::check_passwordless_sudo( Trog::HV->new() ) } );
    ok( !$result->{ok}, 'and failing does not' );
    like( $result->{fix}, qr/NOPASSWD/,                  'the guidance is the sudoers line' );
    like( $result->{fix}, qr/hangs rather than failing/, 'and says why it matters more than it looks' );
    like( $result->{fix}, qr/take it away again/,        'and that it is a real grant of root' );
};

subtest 'rsync is the one thing both ends have to have' => sub {
    my $hv    = Test::MockModule->new('Trog::HV::Libvirt');
    my $which = Test::MockModule->new('File::Which');

    $hv->redefine( is_local => sub { 0 } );
    $hv->redefine( describe => sub { 'doge@hv.test' } );

    # Both there.
    $hv->redefine( run_cmd => sub { 0 } );
    $which->redefine( which => sub { '/usr/bin/rsync' } );
    my ($result) = quietly( sub { Trog::Bin::Preflight::check_rsync( Trog::HV->new() ) } );
    ok( $result->{ok}, 'rsync at both ends passes' );

    # Missing on the hypervisor.
    $hv->redefine( run_cmd => sub { 1 } );
    ($result) = quietly( sub { Trog::Bin::Preflight::check_rsync( Trog::HV->new() ) } );
    ok( !$result->{ok}, 'missing on the hypervisor fails' );
    like( $result->{what}, qr/doge\@hv[.]test/,   'naming the end that has not got it' );
    like( $result->{fix},  qr/apt install rsync/, 'and how to fix it' );

    # Missing here, which is just as fatal and much easier to overlook: this is
    # the machine that runs the rsync, not the one it talks to.
    $hv->redefine( run_cmd => sub { 0 } );
    $which->redefine( which => sub { undef } );
    ($result) = quietly( sub { Trog::Bin::Preflight::check_rsync( Trog::HV->new() ) } );
    ok( !$result->{ok}, 'missing here fails too' );
    like( $result->{what}, qr/this machine/, 'naming this end' );

    # A local hypervisor is one machine, and is not asked twice about it.
    $hv->redefine( is_local => sub { 1 } );
    $hv->redefine( run_cmd  => sub { die 'a local hypervisor should not be asked over ssh' } );
    $which->redefine( which => sub { '/usr/bin/rsync' } );
    ($result) = quietly( sub { Trog::Bin::Preflight::check_rsync( Trog::HV->new() ) } );
    ok( $result->{ok}, 'and a local hypervisor is answered for by this machine' );
};

subtest 'a guest has to have an address of ours to fetch from' => sub {
    my $hv    = Test::MockModule->new('Trog::HV::Libvirt');
    my $local = Test::MockModule->new('Trog::Local');

    $hv->redefine( virbr_ip => sub { '192.168.122.1' } );

    $local->redefine( transfer_ip => sub { '192.168.122.251' } );
    my ( $result, $out ) = quietly( sub { Trog::Bin::Preflight::check_transfer_ip( Trog::HV->new() ) } );
    ok( $result->{ok}, 'an address a guest can route to passes' );
    like( $out, qr/192[.]168[.]122[.]251/, 'and says which one, since nothing else prints it' );

    # A workstation on none of the hypervisor's networks. The guest's very first
    # target fetches from here, so this is the whole run failing later.
    $local->redefine( transfer_ip => sub { undef } );
    ($result) = quietly( sub { Trog::Bin::Preflight::check_transfer_ip( Trog::HV->new() ) } );
    ok( !$result->{ok}, 'no route to the guest network fails' );
    like( $result->{fix}, qr/transfer_ip/, 'and points at the setting that overrides it' );
    like( $result->{fix}, qr/\[global\]/,  'in the section it goes in' );

    # Reported, not thrown: a hypervisor that will not answer about its bridge
    # is one more line in the list rather than the end of the run.
    $hv->redefine( virbr_ip => sub { die "no brctl\n" } );
    ($result) = quietly( sub { Trog::Bin::Preflight::check_transfer_ip( Trog::HV->new() ) } );
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
    my ($result) = quietly( sub { Trog::Bin::Preflight::check_fetch_sources( Trog::HV->new() ) } );
    ok( $result->{ok}, 'a directory that is there passes' );

    $write->("---\n_base:\n    adminconfig:\n        skel: \"$dir/gone\"\none.test:\n    adminconfig:\ntwo.test:\n    openvpnclient:\n        cert_dir: $dir/alsogone\n");
    ($result) = quietly( sub { Trog::Bin::Preflight::check_fetch_sources( Trog::HV->new() ) } );
    ok( !$result->{ok}, 'one that is not fails' );
    like( $result->{what}, qr/\b2 fetched directories/,         'counting the paths rather than the domains that wanted them' );
    like( $result->{fix},  qr{\Q$dir/gone\E \Q(adminconfig)\E}, 'naming the path and the recipe that asked' );
    like( $result->{fix},  qr{alsogone \Q(openvpnclient)\E},    'for each of them' );
    like( $result->{fix},  qr{rsync -a hv[.]test:},             'and how to bring one over from the hypervisor' );

    # Nothing to check is not a failure: a fleet may run no recipe that fetches
    # a directory of the operator's at all.
    $write->("---\none.test:\n    ntp:\n");
    ($result) = quietly( sub { Trog::Bin::Preflight::check_fetch_sources( Trog::HV->new() ) } );
    ok( $result->{ok}, 'and a configuration that fetches nothing passes' );
};

subtest 'the configuration it copies from has to be there' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    my ( $result, $out ) = quietly( sub { Trog::Bin::Preflight::check_config( Trog::HV->new() ) } );
    ok( !$result->{ok}, 'an empty directory fails' );
    like( $out, qr/ipmap\.cfg, recipes\.yaml/, 'naming what is missing' );

    foreach my $file (qw{ipmap.cfg recipes.yaml}) {
        open( my $fh, '>', "$dir/$file" ) or die $!;
        close $fh;
    }
    ($result) = quietly( sub { Trog::Bin::Preflight::check_config( Trog::HV->new() ) } );
    ok( $result->{ok}, 'and passes once they are there' );
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

    like( $out, qr/sudo/,                  'the sudo failure is in there' );
    like( $out, qr/ISO builder/,           'and the ISO builder' );
    like( $out, qr/libvirt/,               'and libvirt' );
    like( $out, qr/Missing from/,          'and the configuration' );
    like( $out, qr/6 things to fix first/, 'counted, all in one run' );
};

subtest 'a distro pinned to an image that has moved on is worth saying so about' => sub {
    my $ubuntu = Test::MockModule->new('Provisioner::Recipe::ubuntu');

    # Current, so there is nothing to report.
    $ubuntu->redefine( current_release => sub { return 'noble' } );
    is_deeply( Trog::Bin::Preflight::note_stale_image(), { ok => 1 }, 'a pin that is current says nothing' );

    # A release behind.
    $ubuntu->redefine( current_release => sub { return 'plucky' } );
    my $note = Trog::Bin::Preflight::note_stale_image();
    ok( !$note->{ok}, 'a pin that has fallen behind is reported' );
    like( $note->{fix}, qr/noble/,  'naming what it builds on' );
    like( $note->{fix}, qr/plucky/, 'and what it would build on now' );

    # A mirror that will not answer is not a reason to hold up a provision, so
    # a distribution with no answer gets no note rather than a wrong one.
    $ubuntu->redefine( current_release => sub { return undef } );
    is_deeply( Trog::Bin::Preflight::note_stale_image(), { ok => 1 }, 'and a distribution that could not be asked says nothing either' );
};

subtest 'a fleet with no package mirror is told what that costs' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my $write = sub {
        File::Slurper::Temp::write_text( "$dir/recipes.yaml", $_[0] );
        Provisioner::Cookbook->forget();
        return Trog::Bin::Preflight::note_apt_mirror();
    };

    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    # A fresh installation has no domains, and so nothing to say this about.
    is_deeply( $write->("---\n_base:\n    nosnap:\n"), { ok => 1 }, 'nothing configured yet, nothing said' );

    my $note = $write->("---\nweb.troglodyne.net:\n    nginx:\n");
    ok( !$note->{ok}, 'domains but no mirror is worth saying' );
    like( $note->{fix}, qr/bin\/new_guest --hostname aptmirror\.troglodyne\.net aptmirror/, 'naming the command, under the parent the fleet already uses' );

    # The more annoying of the two: the work is done and nothing is using it.
    $note = $write->("---\nweb.troglodyne.net:\n    nginx:\naptmirror.troglodyne.net:\n    aptmirror:\n        releases: [noble]\n");
    ok( !$note->{ok}, 'a mirror nobody points at is worth saying louder' );
    like( $note->{what}, qr/aptmirror\.troglodyne\.net mirrors the archive/, 'naming the guest that is doing the mirroring' );
    like( $note->{fix},  qr/mirror: aptmirror\.troglodyne\.net/,             'and the line that would use it' );

    # Either spelling counts as pointing at one.
    is_deeply( $write->("---\n_base:\n    _global:\n        mirror: aptmirror.troglodyne.net\nweb.troglodyne.net:\n    nginx:\n"), { ok => 1 }, 'a mirror in _base _global is enough' );
    is_deeply( $write->("---\nweb.troglodyne.net:\n    ubuntu:\n        mirror: http://m.test/ubuntu\n"),                          { ok => 1 }, 'as is one in a domain distro block' );
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
        return Trog::Bin::Preflight::note_log_destination( Trog::HV->new() );
    };

    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    # Logging is opt-in, so a fleet that has not asked for it has nothing said
    # about it -- unlike a mirror, which every guest pays for not having.
    is_deeply( $write->("---\nweb.troglodyne.net:\n    nginx:\n"), { ok => 1 }, 'no collector and no shipper says nothing' );

    my $note = $write->("---\nlogs.troglodyne.net:\n    logcollector:\n");
    ok( !$note->{ok}, 'a sink with nothing shipping to it is worth saying' );
    like( $note->{what}, qr/logs\.troglodyne\.net collects logs/, 'naming the guest doing the collecting' );
    like( $note->{fix},  qr/host: logs\.troglodyne\.net/,         'and the line that would use it' );

    is_deeply(
        $write->("---\n_base:\n    logshipper:\n        host: logs.troglodyne.net\nlogs.troglodyne.net:\n    logcollector:\n"),
        { ok => 1 }, 'and nothing once the fleet points at it'
    );
};

subtest 'the drop-ins provisioning used to write are worth pointing at' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "---\nweb.troglodyne.net:\n    nginx:\nold.troglodyne.net:\n    nginx:\n" );
    Provisioner::Cookbook->forget();

    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( describe => sub { return 'the hypervisor' } );

    # Only the per-domain ones this tool wrote.  20-ufw.conf and 50-default.conf
    # are the distribution's, and a 10- file for a domain nobody has configured
    # is somebody else's business.
    $hv->redefine(
        list_dir => sub {
            return qw{10-web.troglodyne.net.conf 10-old.troglodyne.net.conf 10-notours.example.conf 20-ufw.conf 50-default.conf};
        }
    );

    my $note = Trog::Bin::Preflight::note_log_destination( Trog::HV->new() );
    ok( !$note->{ok}, 'leftovers are worth a note' );
    like( $note->{what}, qr/\A2 rsyslog drop-ins/, 'counting only the ones written for a domain we know about' );
    unlike( $note->{fix}, qr/notours|20-ufw|50-default/, 'and leaving everything else on that machine alone' );

    # Comma-joined with no spaces, or the brace expansion it prints cannot be
    # pasted into a shell.
    like( $note->{fix}, qr/\Q{old.troglodyne.net,web.troglodyne.net}\E/, 'the removal command is one that would actually run' );
};

done_testing();
