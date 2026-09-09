#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/provision.t - bin/provision: the order it does things in, and the XML it writes

=cut

use Test::More;
use Test::Fatal qw{exception};
use IPC::Run3();
use File::Temp qw{tempdir};
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
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }
use Trog::HV();

# No skip_all if the prereqs are missing: a suite that passes because it never
# ran is worse than one that fails.  bin/provision uses XML::Twig,
# Net::OpenSSH::More and Net::EmptyPort itself, so this explodes and tells you
# the kit is wrong rather than quietly reporting success.
my $script = "$FindBin::Bin/../bin/provision";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# --- The interface lives in POD, and pod2usage prints it ----------------------
subtest 'the POD documents the interface' => sub {
    my $synopsis = _pod_section( $script, 'SYNOPSIS|OPTIONS' );
    like( $synopsis, qr/--connect/,   'POD documents --connect' );
    like( $synopsis, qr/--domaindir/, 'POD documents --domaindir' );
    like( $synopsis, qr/--existing/,  'POD documents --existing' );
    like( $synopsis, qr/--dryrun/,    'POD documents --dryrun' );
    like( $synopsis, qr/--no-config/, 'POD documents --no-config' );
    like( $synopsis, qr/DOMAIN/,      'POD documents the DOMAIN argument' );
};

# pod2usage exits rather than dying, so this has to be a real run.
subtest 'no domain exits with the usage' => sub {
    my $out = q{};
    IPC::Run3::run3( [ $^X, $script ], \undef, \$out, \$out );
    isnt( $?, 0, 'exits non-zero' );
    like( $out, qr/No domain passed/, 'saying what was missing' );
    like( $out, qr/Usage:/,           'and printing the usage out of the POD' );
};

# --- The hypervisor comes off the config, and --connect beats it -------------
#
# Run main() as far as the hypervisor being built and then stop it, so we can
# see what it decided without letting it near a real libvirt or a real ssh.
subtest 'main() resolves the hypervisor before it touches anything' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/vm.example.com";
    File::Slurper::Temp::write_text(
        "$dir/vm.example.com/provision.conf",
        "libvirt_uri=qemu+ssh://root\@confhv/system\nips=203.0.113.10\n"
    );
    File::Slurper::Temp::write_text( "$dir/vm.example.com/users.yaml",  "users: []\n" );
    File::Slurper::Temp::write_text( "$dir/vm.example.com/data.tar.gz", "not really a tarball\n" );

    my $fakebin = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$fakebin/terraform", "#!/bin/sh\nexit 0\n" );
    chmod 0755, "$fakebin/terraform";
    local $ENV{PATH} = "$fakebin:$ENV{PATH}";

    my $no_fleet = tempdir( CLEANUP => 1 ) . '/hypervisors.conf';

    # The config generator runs first now; this test is about what happens
    # after it, so there is nothing for it to generate from.
    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine( mkpath      => sub { 1 } );
    $hv_mock->redefine( file_exists => sub { 1 } );

    # no_auto: the modulino is already loaded from bin/provision, and there is
    # no Trog/Bin/Provisioner.pm for MockModule to go looking for.
    my $bin_mock = Test::MockModule->new( 'Trog::Bin::Provisioner', no_auto => 1 );

    # A tripwire in the first thing provision_domain does, so this stops as soon
    # as the hypervisor has been resolved and nothing after it runs.
    $bin_mock->redefine( read_seed => sub { die "far enough\n" } );

    my $run = sub {
        Trog::HV->forget();
        eval { Trog::Bin::Provisioner::main( '--hvconf', $no_fleet, @_ ) };
        like( $@, qr/\Afar enough$/m, 'got as far as the hypervisor being built' );
        return Trog::HV->new();
    };

    my $hv = $run->( '--domaindir', $dir, 'vm.example.com' );
    is(
        $hv->uri, 'qemu+ssh://root@confhv/system',
        'libvirt_uri from provision.conf reaches the hypervisor object'
    );
    is( $hv->domain_dir, $dir, '--domaindir does too' );

    $hv = $run->(
        '--domaindir', $dir,
        qw{--connect qemu+ssh://root@clihv/system vm.example.com}
    );
    is( $hv->uri, 'qemu+ssh://root@clihv/system', '--connect wins over the config' );
};

# --- Adopting the state a hypervisor already had -----------------------------
# --- Adopting what libvirt already has ---------------------------------------
# --- The config generator runs first -----------------------------------------
# The warning the generator prints is the most it can do: it writes
# configuration and destroys nothing, and it runs from cron to take backups.
# This program is the one that calls clean_domain_resources, so refusing is its
# job.
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
    like( $why, qr/Refusing to rebuild/,                      'it refuses' );
    like( $why, qr{redis read nothing out of /var/lib/redis}, 'naming the recipe and the path' );
    like( $why, qr/vm[.]test/,                                'and the domain it was on' );
    like( $why, qr/--salvage-gaps-ok/,                        'and the way past it' );

    # Said out loud, and then allowed, because somebody typed the flag.
    my @said;
    my $ok = do {
        local $SIG{__WARN__} = sub { push( @said, $_[0] ) };
        Trog::Bin::Provisioner::refuse_on_salvage_gaps(1);
    };
    is( $ok, 1, 'the override lets it through' );
    like( join( q{}, @said ), qr{redis read nothing out of /var/lib/redis}, 'still saying what is being lost' );
};

# It used to stop after clean_domain_resources and after mongle_domain_xml, so a
# dry run annihilated the domain, deleted both its volumes, made a fresh disk and
# a seed, and then reported that it had applied nothing.
subtest 'a dry run applies nothing' => sub {

    # The SUT is a modulino required at runtime, so its `our` is not in scope
    # while this file compiles and perl calls the one mention a typo.
    no warnings 'once';
    local $Trog::Bin::Provisioner::dryrun = 1;
    use warnings 'once';

    my @applied;
    my $hv  = Test::MockModule->new('Trog::HV');
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

    my ( $user, $ip ) = quietly( sub { Trog::Bin::Provisioner::provision_domain( $config, 'vm.test' ) } );

    is_deeply( \@applied, [], 'nothing outside the domain directory was touched' )
      or diag "applied: @applied";
    is( File::Slurper::read_text("$dir/vm.test/key.rsa"), "PRIVATE\n", 'the existing key is still the existing key' );

    # And it still wrote what there is to look at.
    ok( -s "$dir/vm.test/user-data", 'user-data was written' );
    ok( -s "$dir/vm.test/setup.sh",  'and the setup script' );
};

subtest 'a domain directory with no recipes is built as it stands' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my $out = quietly(
        sub {
            Trog::Bin::Provisioner::generate_config( 'vm.example.com', { domain_dir => $dir } );
        }
    );
    is( $out, 0, 'nothing to generate from, so nothing was generated' );
};
subtest 'the outbound adapter is found by MAC, not by name' => sub {
    my $config = Config::Simple->new( _conf( domain => 'vm.example.com' ) );
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
    my $named = Config::Simple->new( _conf( domain => 'vm.example.com', bridge_devname => 'ens3' ) );
    is(
        Trog::Bin::Provisioner::primary_adapter( $old, $named, $mac ), 'ens3',
        'bridge_devname is still honoured'
    );

    # Nothing matching at all is an error that says what it looked for.
    my $neither = { network => { ethernets => { enp0s9 => { addresses => [] } } } };
    eval { Trog::Bin::Provisioner::primary_adapter( $neither, $config, $mac ) };
    like( $@, qr/Could not find the outbound adapter/, 'otherwise it says so' );
    like( $@, qr/enp0s9/,                              'listing what the guest does have' );

    eval { Trog::Bin::Provisioner::primary_adapter( {}, $config, $mac ) };
    like( $@, qr/No ethernets at all/, 'and a netplan with no ethernets is its own error' );
};

sub _conf {
    my (%params) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/provision.conf", join( '', map { "$_=$params{$_}\n" } sort keys %params ) );
    return "$dir/provision.conf";
}

sub quietly {
    my ($code) = @_;
    open( my $capture, '>', \my $out ) or die $!;
    my @result = do { local *STDOUT = $capture; $code->() };
    close $capture;
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
    close $fh;
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
    mkdir "$dir/vm.example.com";
    File::Slurper::Temp::write_text( "$dir/vm.example.com/provision.conf", "admin_user=ubuntu\nips=203.0.113.10\n" );
    File::Slurper::Temp::write_text( "$dir/vm.example.com/users.yaml",     "users: []\n" );
    File::Slurper::Temp::write_text( "$dir/vm.example.com/data.tar.gz",    "not really a tarball\n" );

    my @order;

    my $hv_mock = Test::MockModule->new('Trog::HV');
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

    Trog::HV->forget();
    my $no_fleet = tempdir( CLEANUP => 1 ) . '/hypervisors.conf';
    my $rc       = eval {
        Trog::Bin::Provisioner::main(
            '--no-config', '--hvconf', $no_fleet,
            '--domaindir', $dir,       'vm.example.com'
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

done_testing;
