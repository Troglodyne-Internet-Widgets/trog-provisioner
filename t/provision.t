#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/provision.t - bin/provision: the order it does things in, and the XML it writes

=cut

use Test::More;
use Capture::Tiny qw{capture_stdout};
use Test::Fatal   qw{exception};
use IPC::Run3();
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use Test::MockModule qw{strict};
use Pod::Usage();
use Config::Simple();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo
use Trog::HV();
use Provisioner::Cookbook();

# Loaded so Test::MockModule has a package to attach to: Trog::HV requires its
# backend lazily, and it is named only as a string below.
use Trog::HV::Libvirt();      ## no critic (ProhibitUnusedImports)
use Trog::HV::OpenStack();    ## no critic (ProhibitUnusedImports)

# These patterns quotemeta a literal on purpose: a fixture string this test
# wrote itself, full of dots and slashes that would otherwise need escaping one
# at a time.  The policy is about production code, where a \Q...\E round
# anything but an interpolated value is usually an accident.
## no critic (RegularExpressions::PreventUselessMetacharacterEscapes)

# No skip_all if the prereqs are missing: a suite that passes because it never
# ran is worse than one that fails.  bin/provision uses XML::Twig,
# Net::OpenSSH::More and Net::EmptyPort itself, so this explodes and tells you
# the kit is wrong rather than quietly reporting success.
my $script = "$FindBin::Bin/../bin/provision";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# --- The interface lives in POD, and pod2usage prints it ----------------------
subtest 'the POD documents the interface' => sub {
    my $synopsis = _pod_section( $script, 'SYNOPSIS|OPTIONS' );
    like( $synopsis, qr/--hypervisor/,             'POD documents --hypervisor' );
    like( $synopsis, qr/--domaindir/,              'POD documents --domaindir' );
    like( $synopsis, qr/--existing/,               'POD documents --existing' );
    like( $synopsis, qr/--dryrun/,                 'POD documents --dryrun' );
    like( $synopsis, qr/--clone-on-nonreusable/,   'POD documents --clone-on-nonreusable' );
    like( $synopsis, qr/--destroy-on-nonreusable/, 'POD documents --destroy-on-nonreusable' );
    like( $synopsis, qr/--die-on-nonreusable/,     'POD documents --die-on-nonreusable' );
    like( $synopsis, qr/DOMAIN/,                   'POD documents the DOMAIN argument' );
};

# pod2usage exits rather than dying, so this has to be a real run.
subtest 'no domain exits with the usage' => sub {
    my $out = q{};
    IPC::Run3::run3( [ $^X, $script ], \undef, \$out, \$out );
    isnt( $?, 0, 'exits non-zero' );
    like( $out, qr/No[ ]domain[ ]passed/, 'saying what was missing' );
    like( $out, qr/Usage:/,               'and printing the usage out of the POD' );
};

# A run that names an option this does not have builds nothing.  --no-config is
# the one that was taken away, and a cron line or a script that still passes it
# would otherwise generate the configuration it asked not to.
subtest 'an option that is not there is refused rather than ignored' => sub {
    my $out = q{};
    IPC::Run3::run3( [ $^X, $script, '--no-config', 'vm.test' ], \undef, \$out, \$out );

    isnt( $?, 0, 'exits non-zero' );
    like( $out, qr/Unknown[ ]option:[ ]no-config/, 'naming the option' );
    like( $out, qr/Usage:/,                        'and printing the usage out of the POD' );
};

# A real run, since pod2usage exits rather than dying.  Safe: the refusal comes
# before any credential is asked for.
subtest 'the nonreusable options say different things, so only one is taken' => sub {
    my $out = q{};
    IPC::Run3::run3( [ $^X, $script, qw{--clone-on-nonreusable --destroy-on-nonreusable --die-on-nonreusable vm.test} ], \undef, \$out, \$out );

    isnt( $?, 0, 'passing more than one exits non-zero' );
    like( $out, qr/say[ ]different[ ]things/, 'saying why' );
    like( $out, qr/Usage:/,                   'and printing the usage out of the POD' );
};

# --- The hypervisor comes off the config, and --hypervisor beats it ----------
#
# Run main() as far as the hypervisor being built and then stop it, so we can
# see what it decided without letting it near a real libvirt or a real ssh.

subtest 'main() resolves the hypervisor before it touches anything' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/vm.example.test";
    File::Slurper::Temp::write_text(
        "$dir/vm.example.test/provision.conf",
        "libvirt_uri=qemu+ssh://root\@confhv/system\nips=203.0.113.10\n"
    );
    File::Slurper::Temp::write_text( "$dir/vm.example.test/users.yaml",  "users: []\n" );
    File::Slurper::Temp::write_text( "$dir/vm.example.test/data.tar.gz", "not really a tarball\n" );

    my $fakebin = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$fakebin/terraform", "#!/bin/sh\nexit 0\n" );
    chmod 0755, "$fakebin/terraform";
    local $ENV{PATH} = "$fakebin:$ENV{PATH}";

    my $no_fleet = tempdir( CLEANUP => 1 ) . '/hypervisors.conf';

    # The config generator runs first now; this test is about what happens
    # after it, so there is nothing for it to generate from.
    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( mkpath      => sub { 1 } );
    $hv_mock->redefine( file_exists => sub { 1 } );

    # no_auto: the modulino is already loaded from bin/provision, and there is
    # no Trog/Bin/Provisioner.pm for MockModule to go looking for.
    my $bin_mock = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );

    # A tripwire in the first thing provision_domain does, so this stops as soon
    # as the hypervisor has been resolved and nothing after it runs.
    $bin_mock->redefine( read_seed => sub { die "far enough\n" } );

    my $run = sub {
        my @args = @_;
        Trog::HV->forget();
        like( exception { Trog::Bin::Provisioner::main( '--hvconf', $no_fleet, @args ) }, qr/\Afar[ ]enough$/m, 'got as far as the hypervisor being built' );
        return Trog::HV->new();
    };

    my $hv = $run->( '--domaindir', $dir, 'vm.example.test' );
    is(
        $hv->uri, 'qemu+ssh://root@confhv/system',
        'libvirt_uri from provision.conf reaches the hypervisor object'
    );
    is( $hv->domain_dir, $dir, '--domaindir does too' );

    # A fleet with one hypervisor in it, so that a name has something to name.
    my $fleet = "$dir/hypervisors.conf";
    File::Slurper::Temp::write_text( $fleet, "[clihv]\nlibvirt_uri=qemu+ssh://root\@clihv/system\n" );

    $hv = $run->(
        '--domaindir', $dir, '--hvconf', $fleet,
        qw{--hypervisor clihv vm.example.test}
    );
    is( $hv->uri,  'qemu+ssh://root@clihv/system', '--hypervisor wins over the config' );
    is( $hv->name, 'clihv',                        'and the guest is built on the one it names' );
};

# --- Adopting the state a hypervisor already had -----------------------------
# --- Adopting what libvirt already has ---------------------------------------
# --- The config generator runs first -----------------------------------------
# The warning the generator prints is the most it can do: it writes
# configuration and destroys nothing, and it runs from cron to take backups.
# This program is the one that asks a hypervisor to clear_guest, so refusing is
# its job.
subtest 'a salvage that came away empty stops the run before anything is destroyed' => sub {

    # The real generator, so this is pinned to the interface it actually
    # publishes.  A defined stub would go on passing after somebody renamed
    # salvage_gaps out from under the caller.
    require "$FindBin::Bin/../bin/new_config";    ## no critic (Modules::RequireBarewordIncludes)
    my $gen = Test::MockModule->new( 'Trog::Provisioner::Config::Generator', no_auto => 1 );

    # Nothing unreadable: every first build of a machine looks like this, and a
    # domain with no guest yet is never salvaged at all.
    $gen->redefine( salvage_gaps => sub { () } );
    is( Trog::Bin::Provisioner::refuse_on_salvage_gaps(0), 1, 'no gaps, no refusal' );

    # A directory that is on the guest and came away empty.
    $gen->redefine(
        salvage_gaps => sub {
            return ( 'vm.test' => [ { recipe => 'redis', remote => '/var/lib/redis' } ] );
        }
    );

    my $why = exception { Trog::Bin::Provisioner::refuse_on_salvage_gaps(0) };
    like( $why, qr/Refusing[ ]to[ ]rebuild/,                            'it refuses' );
    like( $why, qr{redis[ ]read[ ]nothing[ ]out[ ]of[ ]/var/lib/redis}, 'naming the recipe and the path' );
    like( $why, qr/vm[.]test/,                                          'and the domain it was on' );
    like( $why, qr/--salvage-gaps-ok/,                                  'and the way past it' );

    # Said out loud, and then allowed, because somebody typed the flag.
    my @said;
    my $ok = do {
        local $SIG{__WARN__} = sub { push( @said, $_[0] ) };
        Trog::Bin::Provisioner::refuse_on_salvage_gaps(1);
    };
    is( $ok, 1, 'the override lets it through' );
    like( join( q{}, @said ), qr{redis[ ]read[ ]nothing[ ]out[ ]of[ ]/var/lib/redis}, 'still saying what is being lost' );
};

# It used to stop after clearing the guest and after rendering the XML -- what
# clear_guest and provision_guest do now -- so a dry run annihilated the domain,
# deleted both its volumes, made a fresh disk and a seed, and then reported that
# it had applied nothing.
# A dry run of a guest that does not exist yet.
#
# The one above mocks domain_exists true, so the case a first build is actually
# in never ran.  bin/provision asked the backend how to reach the address
# would_provision handed back -- and a cloud looks a guest up by name, so for one
# that does not exist that was a die rather than an address.  libvirt hid it by
# handing the placeholder straight back.  main() throws the address away on a dry
# run either way.
subtest 'a dry run of a guest that is not there yet' => sub {
    my $hv  = Test::MockModule->new('Trog::HV::OpenStack');
    my $bin = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );
    my $loc = Test::MockModule->new('Trog::Local');

    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/vm.test";
    File::Slurper::Temp::write_text( "$dir/vm.test/key.rsa",     "PRIVATE\n" );
    File::Slurper::Temp::write_text( "$dir/vm.test/key.rsa.pub", "ssh-rsa AAAA nobody\n" );
    File::Slurper::Temp::write_text( "$dir/vm.test/users.yaml",  "users:\n  - name: doge\n" );

    $hv->redefine( domain_dir    => sub { $dir } );
    $hv->redefine( domain_exists => sub { 0 } );
    $hv->redefine( describe      => sub { 'the cloud' } );
    $loc->redefine( append_line => sub { 1 } );

    # If anything asks, that is the bug: there is no guest to ask about.
    my $asked = 0;
    $hv->redefine( guest_ssh_ip => sub { $asked++; die "There is no guest called 'vm.test'\n" } );

    Trog::HV->forget();

    # Called for what it leaves behind: the instance that the code under test gets.
    Trog::HV->new( cloud => 'testcloud', domain_dir => $dir );

    my $config = Config::Simple->new( syntax => 'simple' );
    $config->param( $_->[0], $_->[1] )
      for (
        [ domain        => 'vm.test' ], [ contact_email => 'nobody@vm.test' ],
        [ admin_user    => 'doge' ],    [ transfer_ip   => '192.168.1.49' ],
        [ transfer_user => 'doge' ],    [ transfer_port => 22 ],
      );

    my ($user) = quietly( sub { Trog::Bin::Provisioner::provision_domain( config => $config, domain => 'vm.test', dryrun => 1 ) } );

    is( $asked, 0,      'nothing asked the cloud how to reach a guest it has not built' );
    is( $user,  'doge', 'and the dry run came back rather than dying' );

    Trog::HV->forget();
};

subtest 'a dry run applies nothing' => sub {
    my @applied;
    my $hv  = Test::MockModule->new('Trog::HV::Libvirt');
    my $bin = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );
    my $loc = Test::MockModule->new('Trog::Local');

    # Everything that reaches past the domain directory, named so a failure says
    # which one it was rather than that a mock died.
    $hv->redefine( domain_exists     => sub { 1 } );
    $hv->redefine( annihilate_domain => sub { push( @applied, 'annihilate_domain' ); 1 } );
    $hv->redefine( delete_volume     => sub { push( @applied, 'delete_volume' );     1 } );
    $hv->redefine( create_disk       => sub { push( @applied, 'create_disk' );       1 } );
    $hv->redefine( cloudinit_iso     => sub { push( @applied, 'cloudinit_iso' );     1 } );
    $hv->redefine( define_domain     => sub { push( @applied, 'define_domain' );     1 } );
    $hv->redefine( write_text        => sub { push( @applied, 'write_text' );        1 } );
    $hv->redefine( put_file          => sub { push( @applied, 'put_file' );          1 } );
    $hv->redefine( run_sudo          => sub { push( @applied, 'run_sudo' );          0 } );
    $loc->redefine( append_line => sub { push( @applied, 'append_line' ); 1 } );

    # The parts a dry run is supposed to do, faked out so the run reaches the end.
    $hv->redefine( virbr_device => sub { 'virbr0' } );
    $hv->redefine( virbr_ip     => sub { '192.168.122.1' } );
    $hv->redefine( sshd_port    => sub { 22 } );
    $hv->redefine( guest_mac    => sub { '52:54:00:aa:bb:cc' } );
    $hv->redefine( lease_ip     => sub { '192.168.122.50' } );
    $hv->redefine( is_local     => sub { 1 } );
    $hv->redefine( describe     => sub { 'the hypervisor' } );

    my $dir = tempdir( CLEANUP => 1 );
    $hv->redefine( domain_dir => sub { $dir } );
    mkdir "$dir/vm.test";

    # A key that is already there, which a dry run must not replace: the guest
    # that is up has its public half.
    File::Slurper::Temp::write_text( "$dir/vm.test/key.rsa",     "PRIVATE\n" );
    File::Slurper::Temp::write_text( "$dir/vm.test/key.rsa.pub", "ssh-rsa AAAA nobody\n" );
    File::Slurper::Temp::write_text( "$dir/vm.test/users.yaml",  "users:\n  - name: doge\n" );

    my $config = Config::Simple->new( syntax => 'simple' );
    $config->param( $_->[0], $_->[1] )
      for (
        [ domain      => 'vm.test' ],       [ contact_email => 'nobody@vm.test' ],
        [ ips         => '192.168.1.9' ],   [ gateway       => '192.168.1.254' ],
        [ resolvers   => '192.168.1.254' ], [ admin_user    => 'doge' ],
        [ size        => 21474836480 ],     [ cpus          => 2 ],      [ memory        => 4096 ],
        [ transfer_ip => '192.168.1.49' ],  [ transfer_user => 'doge' ], [ transfer_port => 22 ],
      );

    quietly( sub { Trog::Bin::Provisioner::provision_domain( config => $config, domain => 'vm.test', dryrun => 1 ) } );

    is_deeply( \@applied, [], 'nothing outside the domain directory was touched' )
      or diag "applied: @applied";
    is( File::Slurper::read_text("$dir/vm.test/key.rsa"), "PRIVATE\n", 'the existing key is still the existing key' );
};

# The unit half of this -- every disk knob against every libvirt version -- is
# t/Provisioner-Recipe-vm.t.  What is left here is the integration claim: that a
# real provision still reaches the recipe, and that what bin/new_config wrote
# beside the domain is what ends up in the seed.
subtest 'a real provision reaches the vm recipe with what new_config wrote' => sub {
    my @applied;
    my $hv  = Test::MockModule->new('Trog::HV::Libvirt');
    my $loc = Test::MockModule->new('Trog::Local');

    my %seeded;
    $hv->redefine( domain_exists => sub { 0 } );

    # No domain yet, so no uuid to carry: the XML leaves the element out and
    # libvirt mints one, which is what a first build has always done.
    $hv->redefine( domain_uuid   => sub { undef } );
    $hv->redefine( delete_volume => sub { 1 } );
    $hv->redefine( pool          => sub { 1 } );
    $hv->redefine( base_image    => sub { '/bogus/pool/baseimage-qcow2' } );
    $hv->redefine( create_disk   => sub { '/bogus/pool/vm.test-qcow2' } );
    $hv->redefine( bridge_device => sub { 'br0' } );
    $hv->redefine( has_tpm       => sub { 0 } );
    $hv->redefine( guest_mac     => sub { '52:54:00:aa:bb:cc' } );
    $hv->redefine( lease_ip      => sub { '192.168.122.50' } );

    # A guest never built before holds no lease to release.
    $hv->redefine( lease_ips            => sub { () } );
    $hv->redefine( is_local             => sub { 1 } );
    $hv->redefine( describe             => sub { 'the hypervisor' } );
    $hv->redefine( virbr_ip             => sub { '192.168.122.1' } );
    $hv->redefine( libvirt_version      => sub { 10_000_000 } );
    $hv->redefine( qemu_version         => sub { 9_000_000 } );
    $hv->redefine( pool_takes_direct_io => sub { 1 } );
    $hv->redefine( pool_fstype          => sub { 'ext4' } );
    $hv->redefine( write_text           => sub { push( @applied, 'write_text' ); 1 } );
    $hv->redefine( put_file             => sub { push( @applied, 'put_file' ); 1 } );
    $hv->redefine( run_sudo             => sub { push( @applied, 'run_sudo' ); 0 } );
    $hv->redefine( define_domain        => sub { push( @applied, 'define_domain' ); 1 } );
    $hv->redefine( cloudinit_iso        => sub { my ( undef, undef, %f ) = @_; %seeded = %f; return '/bogus/pool/seed.iso' } );
    $loc->redefine( append_line => sub { push( @applied, 'append_line' ); 1 } );

    my $dir = tempdir( CLEANUP => 1 );
    $hv->redefine( domain_dir => sub { $dir } );
    mkdir "$dir/vm.test";

    # What bin/new_config leaves beside a domain, which is all this program
    # reads now.  Deliberately recognisable, so that finding it in the seed says
    # it came off disk rather than being rebuilt here.
    my %wrote = (
        'user-data'      => "#cloud-config\nfqdn: vm.test\n",
        'meta-data'      => "instance-id: vm.test\n",
        'network-config' => "network:\n  version: 1\n",
        'key.rsa.pub'    => "ssh-rsa AAAA nobody\n",
    );
    File::Slurper::Temp::write_text( "$dir/vm.test/$_", $wrote{$_} ) for keys %wrote;

    my $config = Config::Simple->new(
        _conf(
            domain     => 'vm.test',   memory => 2048, cpus => 2,
            size       => 42949672960, image  => 'https://example.test/img',
            admin_user => 'doge',      distro => 'ubuntu',
        )
    );

    my ( $user, $ip ) = quietly( sub { Trog::Bin::Provisioner::provision_domain( config => $config, domain => 'vm.test' ) } );

    is_deeply(
        \%seeded,
        { map { $_ => $wrote{$_} } qw{user-data meta-data network-config} },
        'the seed is the three files new_config wrote, unaltered'
    );

    my $xml = File::Slurper::read_text("$dir/vm.test/domain.xml");
    like( $xml, qr{<name>vm\.test</name>},                    'the vm recipe wrote the domain XML' );
    like( $xml, qr{<source[ ]file='/bogus/pool/seed\.iso'/>}, 'naming the seed it just made' );
    unlike( $xml, qr/\[%/, 'with nothing of the template left in it' );

    ok( ( grep { $_ eq 'define_domain' } @applied ), 'and the domain was defined from it' );
    ok( ( grep { $_ eq 'append_line' } @applied ),   "the guest's key was authorized on the machine holding the payload" );

    # Provisioning used to write a per-domain rsyslog drop-in onto the hypervisor
    # and restart rsyslog there, on every build, for a listener that on this
    # installation had never been opened.  Where a guest sends its logs is
    # Provisioner::Recipe::logshipper now and the far end is
    # Provisioner::Recipe::logcollector, so a provision configures nothing
    # outside the guest it is building.
    ok( !( grep { $_ eq 'write_text' } @applied ), 'nothing is written to the hypervisor for logging' );
    ok( !-e "$dir/vm.test/rsyslog-collector.conf", 'and the vm recipe no longer generates a collector configuration' );

    is( $user, 'doge',           'the admin user comes back' );
    is( $ip,   '192.168.122.50', 'with the address the guest leased' );
};

subtest 'a rebuild releases the leases the guests before it held' => sub {
    my @applied;
    my $hv  = Test::MockModule->new('Trog::HV::Libvirt');
    my $loc = Test::MockModule->new('Trog::Local');

    # A guest already there, and two leases on file for its MAC: the one it has,
    # and one an earlier rebuild left behind.  Measured on hydra: a rebuilt
    # guest keeps its MAC and still gets a new address, and dnsmasq keeps the
    # old lease until it expires.
    $hv->redefine( domain_exists => sub { 1 } );

    # About leases, not about whether the rebuild may destroy the guest.
    $hv->redefine( rebuild_destroys_guest => sub { 0 } );
    $hv->redefine( domain_uuid            => sub { '35341952-6f2b-457a-a882-80f6c47e2d2c' } );
    $hv->redefine( annihilate_domain      => sub { push( @applied, 'annihilate_domain' ); 1 } );
    $hv->redefine( lease_ips              => sub { qw{192.168.122.97 192.168.122.96} } );
    $hv->redefine( release_dhcp_lease     => sub { push( @applied, "release $_[1]" ); 1 } );
    $hv->redefine( define_domain          => sub { push( @applied, 'define_domain' ); 1 } );
    $hv->redefine( delete_volume          => sub { 1 } );
    $hv->redefine( pool                   => sub { 1 } );
    $hv->redefine( base_image             => sub { '/bogus/pool/baseimage-qcow2' } );
    $hv->redefine( create_disk            => sub { '/bogus/pool/vm.test-qcow2' } );
    $hv->redefine( bridge_device          => sub { 'br0' } );
    $hv->redefine( has_tpm                => sub { 0 } );
    $hv->redefine( guest_mac              => sub { '52:54:00:aa:bb:cc' } );
    $hv->redefine( lease_ip               => sub { '192.168.122.98' } );
    $hv->redefine( is_local               => sub { 1 } );
    $hv->redefine( describe               => sub { 'the hypervisor' } );
    $hv->redefine( virbr_ip               => sub { '192.168.122.1' } );
    $hv->redefine( libvirt_version        => sub { 10_000_000 } );
    $hv->redefine( qemu_version           => sub { 9_000_000 } );
    $hv->redefine( pool_takes_direct_io   => sub { 1 } );
    $hv->redefine( pool_fstype            => sub { 'ext4' } );
    $hv->redefine( write_text             => sub { 1 } );
    $hv->redefine( put_file               => sub { 1 } );
    $hv->redefine( run_sudo               => sub { 0 } );
    $hv->redefine( cloudinit_iso          => sub { '/bogus/pool/seed.iso' } );
    $loc->redefine( append_line => sub { 1 } );

    my $dir = tempdir( CLEANUP => 1 );
    $hv->redefine( domain_dir => sub { $dir } );
    mkdir "$dir/vm.test";
    File::Slurper::Temp::write_text( "$dir/vm.test/$_->[0]", $_->[1] )
      for [ 'user-data', "#cloud-config\n" ], [ 'meta-data', "instance-id: vm.test\n" ], [ 'network-config', "network:\n  version: 1\n" ], [ 'key.rsa.pub', "ssh-rsa AAAA nobody\n" ];

    my $config = Config::Simple->new(
        _conf(
            domain     => 'vm.test',   memory => 2048, cpus => 2,
            size       => 42949672960, image  => 'https://example.test/img',
            admin_user => 'doge',      distro => 'ubuntu',
        )
    );

    quietly( sub { Trog::Bin::Provisioner::provision_domain( config => $config, domain => 'vm.test' ) } );

    is_deeply(
        [ grep { $_ eq 'annihilate_domain' || m/\Arelease[ ]/ || $_ eq 'define_domain' } @applied ],
        [ 'annihilate_domain', 'release 192.168.122.97', 'release 192.168.122.96', 'define_domain' ],
        'every lease the MAC held is released, after the old guest is gone and before the new one is defined'
    ) or diag "applied: @applied";
};

# Everything a provision_domain needs to reach the end, so the two subtests
# below differ in one thing: the answer the backend gives about rolling back.
sub rebuild_answering {
    my (%answers) = @_;

    my %seen = ( snapshots => [], cleared => {}, asked => [], cloned => [], uuid_asked => 0 );
    my $hv   = Test::MockModule->new('Trog::HV::Libvirt');
    my $loc  = Test::MockModule->new('Trog::Local');

    # The identity the rebuild has to carry forward.  A domain that is kept
    # rather than undefined keeps its uuid, and libvirt refuses to redefine it
    # under any other -- so this being asked for, and reaching the XML, is the
    # difference between a rebuild and "domain already exists with uuid".
    $hv->redefine(
        domain_uuid => sub {
            $seen{uuid_asked}++;
            return '35341952-6f2b-457a-a882-80f6c47e2d2c';
        }
    );

    $hv->redefine( rollback_possible => sub { my ( undef, undef, %o ) = @_; push @{ $seen{asked} }, $o{capacity}; return $answers{rollback_possible} } );
    $hv->redefine(
        create_snapshot => sub {
            my ( undef, undef, $n, %o ) = @_;
            push @{ $seen{snapshots} }, { name => $n, disk_only => $o{disk_only}, leave_down => $o{leave_down} };
            return 1;
        }
    );
    $hv->redefine( clear_guest => sub { my ( undef, undef, %o ) = @_; %{ $seen{cleared} } = %o; return 1 } );

    $hv->redefine( domain_exists => sub { 1 } );

    # Off unless a case asks for it, or every subtest about something else stops
    # to ask too.
    $hv->redefine( rebuild_destroys_guest => sub { $answers{destroys} ? 1 : 0 } );

    # Undef is a copy that did not happen, which the caller must not rebuild over.
    $hv->redefine(
        clone_guest_disk => sub {
            push @{ $seen{cloned} }, $_[1];
            return $answers{clone_fails} ? undef : '/bogus/pool/vm.test.bak-qcow2';
        }
    );
    $hv->redefine( define_domain        => sub { 1 } );
    $hv->redefine( pool                 => sub { 1 } );
    $hv->redefine( base_image           => sub { '/bogus/pool/baseimage-qcow2' } );
    $hv->redefine( create_disk          => sub { '/bogus/pool/vm.test-qcow2' } );
    $hv->redefine( cloudinit_iso        => sub { '/bogus/pool/seed.iso' } );
    $hv->redefine( bridge_device        => sub { 'br0' } );
    $hv->redefine( has_tpm              => sub { 0 } );
    $hv->redefine( guest_mac            => sub { '52:54:00:aa:bb:cc' } );
    $hv->redefine( lease_ip             => sub { '192.168.122.50' } );
    $hv->redefine( is_local             => sub { 1 } );
    $hv->redefine( describe             => sub { 'the hypervisor' } );
    $hv->redefine( virbr_ip             => sub { '192.168.122.1' } );
    $hv->redefine( libvirt_version      => sub { 10_000_000 } );
    $hv->redefine( qemu_version         => sub { 9_000_000 } );
    $hv->redefine( pool_takes_direct_io => sub { 1 } );
    $hv->redefine( pool_fstype          => sub { 'ext4' } );
    $hv->redefine( write_text           => sub { 1 } );
    $hv->redefine( put_file             => sub { 1 } );
    $hv->redefine( run_sudo             => sub { 0 } );
    $loc->redefine( append_line => sub { 1 } );

    my $dir = tempdir( CLEANUP => 1 );
    $hv->redefine( domain_dir => sub { $dir } );
    mkdir "$dir/vm.test";
    File::Slurper::Temp::write_text( "$dir/vm.test/$_->[0]", $_->[1] )
      for [ 'user-data', "#cloud-config\n" ], [ 'meta-data', "instance-id: vm.test\n" ], [ 'network-config', "network:\n  version: 1\n" ], [ 'key.rsa.pub', "ssh-rsa AAAA nobody\n" ];

    my $config = Config::Simple->new(
        _conf(
            domain     => 'vm.test',   memory => 2048, cpus => 2,
            size       => 42949672960, image  => 'https://example.test/img',
            admin_user => 'doge',      distro => 'ubuntu',
        )
    );

    my $said = capture_stdout { Trog::Bin::Provisioner::provision_domain( config => $config, domain => 'vm.test', nonreusable => $answers{nonreusable} ) };
    return ( $said, \%seen );
}

subtest 'a rebuild that can be rolled back is snapshotted before it happens' => sub {
    my ( $said, $seen ) = rebuild_answering( rollback_possible => 1 );

    is( scalar @{ $seen->{snapshots} }, 1, 'a rollback point was taken' );
    like( $seen->{snapshots}[0]{name}, qr/\A before-reprovision- \d{4}-\d{2}-\d{2}-\d{6} \z/, 'named for what it is and when it was taken' );

    # The size this build is asking for, which is what decides whether the disk
    # the snapshot lives in can be kept at all.
    is( $seen->{asked}[0],           42949672960, 'the backend was asked about the size being built' );
    is( $seen->{cleared}{keep_disk}, 1,           'and told to keep the disk the snapshot is inside' );

    like( $said, qr{bin/restore [ ] --name [ ] before-reprovision}, 'and the operator is told how to go back' );

    # Disk only, which is what takes a libvirt guest down -- and a snapshot of a
    # running domain that carries no memory is refused outright, error 84.  The
    # guest is about to be rebuilt, so there is no memory here worth writing.
    ok( $seen->{snapshots}[0]{disk_only},  'the rollback point is asked for disk-only, which is the only kind libvirt takes here' );
    ok( $seen->{snapshots}[0]{leave_down}, 'and asked to leave the guest down, the rebuild being about to take it apart anyway' );

    # Keeping the disk means leaving the domain defined, and libvirt binds a
    # name to a uuid: a rebuild that writes XML without the one it already has
    # is refused with "domain already exists with uuid", which is where this
    # came from.  Measured on a hypervisor, twice.
    ok( $seen->{uuid_asked}, 'and the uuid it is already bound to is asked for, to be carried into the new XML' );
};

subtest 'a rebuild that cannot be rolled back is not snapshotted, and says so by saying nothing' => sub {
    my ( $said, $seen ) = rebuild_answering( rollback_possible => 0 );

    # A snapshot here would be taken inside a disk that is about to be deleted,
    # which is worse than not taking one: it reads as a rollback that exists.
    is_deeply( $seen->{snapshots}, [], 'nothing was snapshotted, so nothing stopped the guest for one either' );
    is( $seen->{cleared}{keep_disk}, q{}, 'and the disk goes, the way it always did' );
    unlike( $said, qr{bin/restore}, 'with no rollback offered that would not be there' );
};

subtest 'a rebuild that would destroy the guest stops, unless it is told not to' => sub {

    # Nothing answers under prove, so this falls to the no-tty rule rather than
    # to a prompt.
    my $refused = exception { rebuild_answering( rollback_possible => 0, destroys => 1 ) };
    like( $refused, qr/Refusing[ ]to[ ]rebuild[ ]vm[.]test/, 'with nobody there to ask, it refuses rather than asking' );
    like( $refused, qr/--destroy-on-nonreusable/,            'and names the way past it' );

    my ( $said, $seen ) = rebuild_answering(
        rollback_possible => 0,
        destroys          => 1,
        nonreusable       => $Trog::Bin::Provisioner::NONREUSABLE{destroy},
    );
    like( $said, qr/Rebuilding[ ]vm[.]test[ ]destroys[ ]it/, 'told to destroy it, it says so out loud first' );
    is( $seen->{cleared}{keep_disk}, q{}, 'and goes on to clear the guest, which is what being told that means' );

    my $stopped = exception {
        rebuild_answering(
            rollback_possible => 0,
            destroys          => 1,
            nonreusable       => $Trog::Bin::Provisioner::NONREUSABLE{stop},
        );
    };
    like( $stopped, qr/Refusing[ ]to[ ]rebuild/, 'and told to refuse, it refuses without asking anybody' );
};

subtest 'asked to copy the disk aside, it copies before it destroys' => sub {
    my ( $said, $seen ) = rebuild_answering(
        rollback_possible => 0,
        destroys          => 1,
        nonreusable       => $Trog::Bin::Provisioner::NONREUSABLE{clone},
    );

    is_deeply( $seen->{cloned}, ['vm.test'], 'the backend was asked to copy the disk aside' );
    like( $said, qr/Copied[ ]vm[.]test's[ ]disk[ ]aside/, 'and says where the copy went' );
    like( $said, qr/nothing[ ]removes[ ]that/,            'and that nothing will clean it up for them' );
    is( $seen->{cleared}{keep_disk}, q{}, 'and only then is the guest cleared' );

    # A copy that did not happen must not be rebuilt over.
    my $refused = exception {
        rebuild_answering(
            rollback_possible => 0,
            destroys          => 1,
            clone_fails       => 1,
            nonreusable       => $Trog::Bin::Provisioner::NONREUSABLE{clone},
        );
    };
    like( $refused, qr/Could[ ]not[ ]copy[ ]vm[.]test's[ ]disk[ ]aside/, 'a copy that failed stops the rebuild' );
};

subtest 'a domain directory with no recipes is built as it stands' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my $out = quietly(
        sub {
            Trog::Bin::Provisioner::generate_config( 'vm.example.test', { domain_dir => $dir } );
        }
    );
    is( $out, 0, 'nothing to generate from, so nothing was generated' );
};
subtest 'the outbound adapter is found by MAC, not by name' => sub {
    my $config = Config::Simple->new( _conf( domain => 'vm.example.test' ) );
    my $mac    = '52:54:00:AA:BB:CC';

    # cloud-init writes the MAC it matched on, so the entry identifies itself
    # whatever the guest ended up calling it.
    my $renamed = {
        network => {
            ethernets => {
                eth9   => { match => { macaddress => '52:54:00:11:22:33' }, addresses => ['10.0.0.1/24'] },
                wibble => { match => { macaddress => lc $mac },             addresses => ['203.0.113.1/24'] },
            }
        }
    };
    is(
        Trog::Bin::Provisioner::primary_adapter( $renamed, $config, $mac ), 'wibble',
        'found by MAC even under a name nothing would have guessed'
    );

    is(
        Trog::Bin::Provisioner::primary_adapter( $renamed, $config, uc $mac ), 'wibble',
        'and case does not matter'
    );

    # A guest from before any of this has no match stanza; fall back to the name.
    my $old = {
        network => {
            ethernets => {
                ens3 => { addresses => [] },
                ens4 => { addresses => ['203.0.113.1/24'] },
            }
        }
    };
    is(
        Trog::Bin::Provisioner::primary_adapter( $old, $config, $mac ), 'ens4',
        'an older guest falls back to the derived name'
    );

    # And an explicit override still wins that fallback.
    my $named = Config::Simple->new( _conf( domain => 'vm.example.test', bridge_devname => 'ens3' ) );
    is(
        Trog::Bin::Provisioner::primary_adapter( $old, $named, $mac ), 'ens3',
        'bridge_devname is still honoured'
    );

    # Nothing matching at all is an error that says what it looked for.
    my $neither = { network => { ethernets => { enp0s9 => { addresses => [] } } } };
    my $err     = exception { Trog::Bin::Provisioner::primary_adapter( $neither, $config, $mac ) };
    like( $err, qr/Could[ ]not[ ]find[ ]the[ ]outbound[ ]adapter/, 'otherwise it says so' );
    like( $err, qr/enp0s9/,                                        'listing what the guest does have' );

    like( exception { Trog::Bin::Provisioner::primary_adapter( {}, $config, $mac ) }, qr/No[ ]ethernets[ ]at[ ]all/, 'and a netplan with no ethernets is its own error' );
};

# Reusing a guest means provisioning onto one that is already up, which is how a
# shared host gets built: bar.test is layered onto the guest depends_on named
# rather than being given one of its own.  So $domain is not always the machine,
# and the two things that follow from that are what these check -- which address
# is connected to, and whether clearing $domain takes the target away with it.

subtest 'a domain layered onto the guest built for another' => sub {
    my %seen = _layered( domain => 'bar.test', reuse => '192.168.122.50', depends => 'foo.test' );

    # foo.test's guest is the machine; bar.test has none, which is the whole
    # point of depending on one.  Deriving the address from bar.test's own MAC
    # asked for a lease that cannot exist -- and on OpenStack, for a server of
    # that name, which does not either.
    is( $seen{host}, '192.168.122.50', 'is reached where provisioning that one left it' );
    like( $seen{key}, qr{/foo[.]test/key[.]rsa\z}, "and opened with that guest's own key" );

    is_deeply( $seen{cleared}, ['bar.test'], "any VM still standing under this domain's own name is taken away" );
    ok( $seen{finished}, 'and the reprovision runs to the end' );
    is( $seen{returned}, '192.168.122.50', 'handing back where the guest is' );
};

subtest 'a domain reprovisioned onto a guest of its own' => sub {
    my %seen = _layered( domain => 'vm.test', reuse => '192.168.122.50' );

    is( $seen{host}, '192.168.122.50', 'is reached at the address --existing named' );
    is_deeply( $seen{cleared}, [], 'and nothing is annihilated, that name being the machine itself' );
    ok( $seen{finished}, 'while the reprovision still runs to the end' );
};

subtest 'a dependency with no configuration is named as the one that is missing' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/tenant.test";
    File::Slurper::Temp::write_text( "$dir/tenant.test/provision.conf", "ips=203.0.113.11\ndepends_on=host.test\n" );
    File::Slurper::Temp::write_text( "$dir/tenant.test/users.yaml",     "users: []\n" );
    File::Slurper::Temp::write_text( "$dir/tenant.test/data.tar.gz",    "not really a tarball\n" );

    my $no_fleet = tempdir( CLEANUP => 1 ) . '/hypervisors.conf';

    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( mkpath       => sub { 1 } );
    $hv_mock->redefine( file_exists  => sub { 1 } );
    $hv_mock->redefine( prepare_host => sub { 1 } );

    # Every provision generates, and what is under test here is the guard that
    # reads what generation wrote.  So the generation is the step that is faked.
    my $bin_mock = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );
    $bin_mock->redefine( generate_config => sub { 1 } );

    Trog::HV->forget();
    my $err = exception {
        quietly( sub { Trog::Bin::Provisioner::main( '--hvconf', $no_fleet, '--domaindir', $dir, 'tenant.test' ) } )
    };

    # The guard read the tenant's own provision.conf, which is right there, so a
    # dependency that was never configured got past it and died in
    # Config::Simple instead -- naming neither file.
    like( $err, qr/No[ ]provision\.conf[ ]for[ ]host\.test/, 'the dependency is what it complains about' );
    like( $err, qr{\Q$dir/host.test/provision.conf\E},       'and it names the file that is actually absent' );
    unlike( $err, qr{\Q$dir/tenant.test/provision.conf\E}, 'rather than the one that is present' );
};

# What a reprovision did, without doing any of it: which machine it connected
# to, with whose key, and what it asked the hypervisor to destroy on the way.
sub _layered {
    my (%params) = @_;
    my ( $domain, $reuse, $depends ) = @params{qw{domain reuse depends}};

    my $dir  = tempdir( CLEANUP => 1 );
    my %seen = ( cleared => [] );

    # The key each guest is opened with, on disk -- which is what a domain built
    # before there was a store still has.  Trog::Guest->key_path hands back the
    # file when there is one, and that is the case this subtest is about.
    foreach my $d ( grep { defined } $domain, $depends ) {
        mkdir "$dir/$d";
        File::Slurper::Temp::write_text( "$dir/$d/key.rsa", "PRIVATE\n" );
    }

    my $hv    = Test::MockModule->new('Trog::HV::Libvirt');
    my $bin   = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );
    my $guest = Test::MockModule->new('Trog::Guest');

    $hv->redefine( domain_dir  => sub { $dir } );
    $hv->redefine( guest_mac   => sub { '52:54:00:aa:bb:cc' } );
    $hv->redefine( clear_guest => sub { push( @{ $seen{cleared} }, $_[1] ); 1 } );

    # Left fatal rather than mocked to an answer.  A domain being layered onto
    # another's guest has no lease and no server of its own, so either question
    # is one with no answer, and the address is already in hand.
    $hv->redefine( lease_ip     => sub { die "went looking for a lease\n" } );
    $hv->redefine( guest_ssh_ip => sub { die "asked the hypervisor where to connect\n" } );

    $guest->redefine(
        new => sub {
            my ( $class, %guest_args ) = @_;
            @seen{qw{host key}} = @guest_args{qw{host key_path}};
            return bless {}, $class;
        }
    );
    $guest->redefine( put_file    => sub { 1 } );
    $guest->redefine( capture_cmd => sub { q{} } );

    # The guest-side work has subtests of its own; this is about which machine
    # that work is aimed at.
    $bin->redefine( read_seed             => sub { () } );
    $bin->redefine( authorize_guest_key   => sub { 1 } );
    $bin->redefine( refresh_cloud_init    => sub { 1 } );
    $bin->redefine( merge_guest_addresses => sub { 1 } );
    $bin->redefine( place_guest_secrets   => sub { $seen{finished} = 1; 1 } );

    my $config = Config::Simple->new( _conf( domain => $domain, admin_user => 'doge' ) );
    ( $seen{user}, $seen{returned} ) = quietly( sub { Trog::Bin::Provisioner::provision_domain( config => $config, domain => $domain, reuse => $reuse, reuser => 'doge', depends => $depends ) } );

    return %seen;
}

sub _conf {
    my (%params) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/provision.conf", join( '', map { "$_=$params{$_}\n" } sort keys %params ) );
    return "$dir/provision.conf";
}

sub quietly {
    my ($code) = @_;
    my ( undef, @result ) = capture_stdout { $code->() };
    return wantarray ? @result : $result[0];
}

sub _pod_section {
    my ( $file, $sections ) = @_;
    open( my $fh, '>', \my $text ) or die $!;
    Pod::Usage::pod2usage(
        -input    => $file,
        -output   => $fh,
        -exitval  => 'NOEXIT',
        -verbose  => 99,
        -sections => $sections,
    );
    close($fh) or die "Could not close the POD read out of $file: $!";
    return $text // '';
}

subtest 'the seed ISO is not ejected until cloud-init has read it' => sub {

    # The guest's MAC is derived from its name, so a rebuilt guest asks for --
    # and is given -- the lease it had last time.  libvirt's lease table keeps
    # that across a shutdown, so the address is usually already there before the
    # new guest has finished POSTing.  Ejecting the seed on the strength of it
    # pulled the ISO out seconds after start, and the guest came up with no
    # user, no keys and no netplan.  Order is the whole fix, so it is what this
    # asserts.
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/vm.example.test";
    File::Slurper::Temp::write_text( "$dir/vm.example.test/provision.conf", "admin_user=ubuntu\nips=203.0.113.10\n" );
    File::Slurper::Temp::write_text( "$dir/vm.example.test/users.yaml",     "users: []\n" );
    File::Slurper::Temp::write_text( "$dir/vm.example.test/data.tar.gz",    "not really a tarball\n" );

    my @order;

    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
    $hv_mock->redefine( mkpath      => sub { 1 } );
    $hv_mock->redefine( file_exists => sub { 1 } );
    $hv_mock->redefine( domain_dir  => sub { $dir } );
    $hv_mock->redefine( pool_path   => sub { "$dir/disks" } );
    $hv_mock->redefine( eject_cdrom => sub { push @order, 'eject'; 1 } );

    my $guest_mock = Test::MockModule->new('Trog::Guest');
    $guest_mock->redefine( wait_for_ssh        => sub { push @order, 'ssh';       $_[0] } );
    $guest_mock->redefine( wait_for_cloud_init => sub { push @order, 'cloudinit'; 1 } );
    $guest_mock->redefine( wait_for_makefile   => sub { push @order, 'makefile';  1 } );

    my $bin_mock = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );
    $bin_mock->redefine( provision_domain => sub { push @order, 'provision'; return ( 'ubuntu', '203.0.113.10' ) } );

    # The order of the steps after the configuration is what this is about, and
    # the domain directory here is written by hand rather than generated.
    $bin_mock->redefine( generate_config => sub { 1 } );

    # main() calls this itself, so mocking provision_domain does not cover it,
    # and what it does with the secret store is another subtest's business.
    $bin_mock->redefine( place_guest_secrets => sub { 1 } );

    Trog::HV->forget();
    my $no_fleet = tempdir( CLEANUP => 1 ) . '/hypervisors.conf';
    my $rc       = eval {
        Trog::Bin::Provisioner::main(
            '--hvconf',    $no_fleet,
            '--domaindir', $dir, 'vm.example.test'
        );
    };
    is( $@,  '', 'main() runs to the end' ) or diag $@;
    is( $rc, 0,  'and reports success' );

    is_deeply(
        \@order, [qw{provision ssh cloudinit eject makefile}],
        'the seed comes out after cloud-init is done, not before'
    );

    my ($eject) = grep { $order[$_] eq 'eject' } 0 .. $#order;
    my ($ci)    = grep { $order[$_] eq 'cloudinit' } 0 .. $#order;
    ok( $eject > $ci, 'and never on the strength of a lease alone' );
};

# --- Placing what a recipe reads but must not generate ------------------------
subtest 'a domain that asked for no secret has nothing to place' => sub {
    my $dir    = tempdir( CLEANUP => 1 );
    my $domain = 'nosecrets.test.test';
    mkdir "$dir/$domain";

    Trog::HV->forget();
    Trog::HV->new( uri => 'qemu+ssh://root@hv/system', domain_dir => $dir );

    ok( !-e "$dir/$domain/guest-secrets.yaml", 'new_config left no manifest, which is the state most guests are in' );

    # undef for the guest on purpose: anything carrying on past the manifest
    # reaches the store or the guest, and both of those are a method call on it.
    is( exception { Trog::Bin::Provisioner::place_guest_secrets( undef, $domain ) }, undef, 'so placing secrets does nothing, rather than dying on the way to a guest that wanted none' );
};

# --- Letting a runner in to a hypervisor --------------------------------------
#
# A change to a machine that is not the guest, and the reason this lives here
# rather than in the recipe that declares the key.  It is done where the key has
# already come out of the store, because doing it anywhere else means asking for
# the store password twice.
subtest 'a runner is authorized on each hypervisor it was configured for' => sub {
    my $dir    = tempdir( CLEANUP => 1 );
    my $domain = 'runner.test.test';
    mkdir "$dir/$domain";

    Trog::HV->forget();
    Trog::HV->new( uri => 'qemu+ssh://root@hv/system', domain_dir => $dir );

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine(
        domain_config => sub {
            return {
                trogrunner => {
                    hypervisor_access  => 'least',
                    restrict_key_to_ip => 0,
                    hypervisors        => {
                        one => { libvirt_uri => 'qemu+ssh://runner@one.test.test/system' },
                        two => { libvirt_uri => 'qemu+ssh://runner@two.test.test/system' },
                    },
                },
            };
        }
    );

    my %appended;
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( authorized_keys => sub { $_[0]->ssh_host } );
    $hv->redefine( append_line     => sub { push @{ $appended{ $_[1] } }, $_[2]; return 1 } );

    my $private = _throwaway_key();
    my %values  = ( "/opt/domains/$domain/.ssh/id_ed25519" => $private );

    _quietly( sub { Trog::Bin::Provisioner::authorize_runner_key( $domain, \%values ) } );

    is_deeply( [ sort keys %appended ], [qw{one.test.test two.test.test}], 'one line per hypervisor, and no others' );
    like( $appended{'one.test.test'}[0], qr/\Assh-ed25519[ ]/, 'the public half, derived rather than stored' );
    is( scalar @{ $appended{'one.test.test'} }, 1, 'once each' );

    # A derived public key is the key and nothing else, so an unnamed line is
    # one nobody reading that hypervisor's authorized_keys can attribute.
    like( $appended{'one.test.test'}[0], qr/\Qtrog-provisioner runner runner.test.test\E\z/, 'and it says whose it is' );

    # bin/destroy reads this rather than the store, so that taking the grant
    # away never stops to ask for a passphrase.
    my $written = File::Slurper::read_text("$dir/$domain/hypervisor-key.pub");
    chomp $written;
    is( $written, $appended{'one.test.test'}[0], 'and written beside the domain for the revoke' );
};

subtest 'a guest that is not a runner, or one that asked for nothing' => sub {
    my $touched = 0;
    my $hv      = Test::MockModule->new('Trog::HV');
    $hv->redefine( append_line => sub { $touched++; return 1 } );

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( domain_config => sub { {} } );
    is( Trog::Bin::Provisioner::authorize_runner_key( 'plain.test.test', {} ), 0, 'not a runner: nothing to do' );

    # none is the default, and it is the whole of what turns the grant off:
    # the recipe declares the key whether or not anybody trusts it.
    $cookbook->redefine( domain_config => sub { { trogrunner => { hypervisors => { one => { libvirt_uri => 'qemu+ssh://r@one.test.test/system' } } } } } );
    is( Trog::Bin::Provisioner::authorize_runner_key( 'runner.test.test', {} ), 0, 'a runner with the default access: still nothing' );

    is( $touched, 0, 'neither of them reached a hypervisor' );
};

# The recipe's own generator, rather than a key made some other way here.  A
# made-up string would only prove that CryptX rejects made-up strings, and a key
# from ssh-keygen would not exercise the thing that actually goes in the store --
# which has a rewrap in it precisely because the two do not agree by default.
sub _throwaway_key {
    my %secrets = Provisioner::Cookbook->load('trogrunner')->guest_secrets( '/bogus/domains', 'runner.test.test' );
    my ($entry) = values %secrets;
    return $entry->{generate}->();
}

sub _quietly {
    my ($code) = @_;
    my ( undef, @result ) = capture_stdout { $code->() };
    return wantarray ? @result : $result[0];
}

# The generator places the guest, so it has to place it in the fleet that
# --hvconf names, which is the one choose_hypervisor reads afterwards.
subtest 'the generator is handed the fleet that --hvconf names' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "_base:\n" );

    require "$FindBin::Bin/../bin/new_config";    ## no critic (Modules::RequireBarewordIncludes)
    my @flags;
    my $generator = Test::MockModule->new( 'Trog::Provisioner::Config::Generator', no_auto => 1 );
    $generator->redefine( main         => sub { @flags = @_; return 0 } );
    $generator->redefine( salvage_gaps => sub { return () } );

    quietly(
        sub {
            Trog::Bin::Provisioner::generate_config( 'vm.test.test', { domain_dir => $dir, recipes => "$dir/recipes.yaml", hvconf => '/bogus/fleet.conf' } );
        }
    );
    my %given = @flags[ 0 .. $#flags - 1 ];
    is( $given{'--hvconf'}, '/bogus/fleet.conf', 'passed on to the generator' );

    quietly( sub { Trog::Bin::Provisioner::generate_config( 'vm.test.test', { domain_dir => $dir, recipes => "$dir/recipes.yaml" } ) } );
    %given = @flags[ 0 .. $#flags - 1 ];
    ok( !exists $given{'--hvconf'},     'and not passed when there is none, so the generator reads the default' );
    ok( !exists $given{'--hypervisor'}, 'nor --hypervisor' );
    ok( !exists $given{'--domaindir'},  'nor a domain directory that was only the default' );

    # The generator chooses the hypervisor, so --hypervisor and a --domaindir
    # from the command line go to it, as --hvconf does.
    quietly(
        sub {
            Trog::Bin::Provisioner::generate_config(
                'vm.test.test',
                {
                    domain_dir       => $dir,
                    domain_dir_given => $dir,
                    recipes          => "$dir/recipes.yaml",
                    hypervisor       => 'hv1',
                }
            );
        }
    );
    %given = @flags[ 0 .. $#flags - 1 ];
    is( $given{'--hypervisor'}, 'hv1', '--hypervisor is passed on' );
    is( $given{'--domaindir'},  $dir,  'and so is a --domaindir from the command line' );
};

done_testing;
