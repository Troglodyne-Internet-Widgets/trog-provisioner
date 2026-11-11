#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/guest_network.t - bin/guest_network: the libvirt network that it makes for the
guests of a block, and the bridge that it lets their account join

=head1 DESCRIPTION

The hypervisor is a fake: a hash of the networks of its system daemon and of its
files, and mocks of the L<Trog::HV::Libvirt> calls that ask it and change it.  A
second run against what the first one left is how the test knows that each step
asks before it acts.

=cut

use Test::More;
use Capture::Tiny    qw{capture_stdout};
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempdir};
use File::Slurper::Temp();
use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- set before anything reads the configuration directory.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

# Loaded so Test::MockModule has a package to attach to, and for the constant of
# the XML of a network that is not running.
use Trog::HV::Libvirt();    ## no critic (ProhibitUnusedImports)
use Sys::Virt();            ## no critic (ProhibitUnusedImports)

my $script = "$FindBin::Bin/../bin/guest_network";
require_ok($script) or BAIL_OUT("$script does not load");

my $ACL     = '/etc/qemu/trog-runner-runner.conf';
my $BRIDGES = '/etc/qemu/bridge.conf';

sub hvconf (%clod) {
    my %block = (
        libvirt_uri    => 'qemu+ssh://runner@hv1.test.test/session',
        network        => 'clod',
        resolvers      => '10.0.0.1',
        virbr_device   => 'virbr0',
        bridge_device  => 'virbr1',
        nics           => 'virbr0, virbr1',
        gateway        => '10.0.0.1',
        pool_cidr      => '10.0.0.64/26',
        pool_addresses => '10.0.0.5',
        %clod,
    );
    my $file = tempdir( CLEANUP => 1 ) . '/hypervisors.conf';
    File::Slurper::Temp::write_text(
        $file,
        "[hv1]\nlibvirt_uri = qemu+ssh://someadmin\@hv1.test.test/system\nbridge_device = br0\nvirbr_device = virbr0\n\n[other]\nlibvirt_uri = qemu+ssh://someadmin\@hv2.test.test/system\n\n[clod]\n" . join( q{}, map { "$_ = $block{$_}\n" } grep { $block{$_} ne q{} } sort keys %block )
    );
    return $file;
}

# What the fake hypervisor has.  The default network is there, as on any host
# with libvirt.
sub fresh_state {
    return {
        networks => {
            default => {
                xml       => "<network><name>default</name><uuid>u-default</uuid><forward mode='nat'/><bridge name='virbr0'/><ip address='192.168.122.1' netmask='255.255.255.0'><dhcp><range start='192.168.122.2' end='192.168.122.254'/></dhcp></ip></network>",
                active    => 1,
                autostart => 1,
            },
        },
        files   => { $BRIDGES => "allow br0" },
        root    => [],
        defined => 0,
        started => 0,
    };
}

{

    package Test::FakeNetwork;
    sub new                 ( $class, $state, $name ) { return bless { state => $state, name => $name }, $class }
    sub net                 ($self)                   { return $self->{state}{networks}{ $self->{name} } }
    sub get_name            ($self)                   { return $self->{name} }
    sub get_uuid_string     ($self)                   { return ( $self->net->{xml} =~ m{<uuid>([^<]+)</uuid>} )[0] }
    sub get_bridge_name     ($self)                   { return ( $self->net->{xml} =~ m{<bridge[ ]name='([^']+)'} )[0] }
    sub is_active           ($self)                   { return $self->net->{active} }
    sub get_autostart       ($self)                   { return $self->net->{autostart} }
    sub get_xml_description ( $self, @ )              { return $self->net->{xml} }
    sub create ($self) { $self->{state}{started}++; return $self->net->{active} = 1 }
    sub set_autostart ( $self, $on ) { return $self->net->{autostart} = $on }

    package Test::FakeVmm;
    sub new ( $class, $state ) { return bless { state => $state }, $class }

    sub list_all_networks ($self) {
        return map { Test::FakeNetwork->new( $self->{state}, $_ ) } sort keys %{ $self->{state}{networks} };
    }

    sub get_network_by_name ( $self, $name ) {
        die "Network not found: no network with matching name '$name'\n" unless $self->{state}{networks}{$name};
        return Test::FakeNetwork->new( $self->{state}, $name );
    }

    # libvirt keeps the uuid of a network that it defines again, and refuses
    # a definition under a known name with another one.
    sub define_network ( $self, $xml ) {
        my ($name) = $xml =~ m{<name>([^<]+)</name>};
        my $old    = $self->{state}{networks}{$name};
        my ($uuid) = $xml =~ m{<uuid>([^<]+)</uuid>};
        die "network '$name' already exists with another uuid\n" if $old && !defined $uuid;
        $xml =~ s{</name>}{</name><uuid>u-$name</uuid>} unless defined $uuid;
        $self->{state}{defined}++;
        $self->{state}{networks}{$name} = { %{ $old // {} }, xml => $xml };
        return Test::FakeNetwork->new( $self->{state}, $name );
    }
}

sub run_tool ( $state, @args ) {
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( vmm         => sub ($hv) { Test::FakeVmm->new($state) } );
    $mock->redefine( network_vmm => sub ($hv) { Test::FakeVmm->new($state) } );
    $mock->redefine(
        capture_cmd => sub ( $hv, $cmd ) {
            my ($file) = $cmd =~ m{\Asudo[ ]-n[ ]cat[ ]'([^']+)'} or die "the fake hypervisor was not expecting: $cmd\n";
            return $state->{files}{$file} // q{};
        }
    );
    $mock->redefine(
        run_sudo => sub ( $hv, @argv ) {
            push @{ $state->{root} }, "@argv";
            return "@argv" eq 'install -d -m 0755 /etc/qemu' ? 0 : die "the fake hypervisor was not expecting: @argv\n";
        }
    );
    $mock->redefine(
        write_text => sub ( $hv, $path, $text, %opts ) {
            push @{ $state->{root} }, "write $path";
            chomp( $state->{files}{$path} = $text );
            return 1;
        }
    );

    my $rc;
    my $said = capture_stdout { $rc = Trog::Bin::GuestNetwork::main(@args) };
    return ( $rc, $said );
}

my @run = ( qw{--hypervisor clod --via hv1}, '--hvconf', hvconf() );

subtest 'a dry run prints the network and what it would change, and changes nothing' => sub {
    my $state = fresh_state();
    my ( $rc, $said ) = run_tool( $state, @run, '--dryrun' );

    is( $rc, 0, 'it exits 0' );
    like( $said, qr{<name>clod</name>},                                'the network, named after the network of the block' );
    like( $said, qr{<forward[ ]mode='nat'/>},                          'with NAT' );
    like( $said, qr{<bridge[ ]name='virbr1'[ ]stp='on'[ ]delay='0'/>}, 'on the bridge_device of the block' );
    like( $said, qr{<ip[ ]address='10[.]0[.]0[.]1'[ ]prefix='24'/>},   'at its gateway' );
    unlike( $said, qr/<dhcp/, 'and no DHCP, because every guest on it has its address from the pool' );
    like( $said, qr/would[ ]define[ ]the[ ]network[ ]clod/,                    'it says that it would define it' );
    like( $said, qr/would[ ]start[ ]the[ ]network[ ]clod$/m,                   'start it' );
    like( $said, qr/would[ ]start[ ]the[ ]network[ ]clod[ ]with[ ]the[ ]host/, 'and start it with the host' );
    like( $said, qr{would[ ]let[ ]runner[ ]join[ ]virbr1[ ]in[ ]\Q$ACL\E},     'and let the account of the session join the bridge' );
    like( $said, qr{would[ ]include[ ]\Q$ACL\E[ ]in[ ]\Q$BRIDGES\E},           'through the file that bridge.conf includes' );
    like( $said, qr/Nothing[ ]changed:[ ]5[ ]step/,                            'counting each step' );

    is( $state->{defined}, 0, 'nothing was defined' );
    is( $state->{started}, 0, 'or started' );
    is_deeply( $state->{root}, [], 'and nothing ran as root' );
};

subtest 'a run makes the network once, and a second run finds nothing to do' => sub {
    my $state = fresh_state();
    my ( $rc, $said ) = run_tool( $state, @run );

    is( $rc, 0, 'it exits 0' );
    my $clod = $state->{networks}{clod};
    ok( $clod, 'the network is defined' ) or return;
    like( $clod->{xml}, qr{<bridge[ ]name='virbr1'}, 'on its bridge' );
    ok( $clod->{active},    'running' );
    ok( $clod->{autostart}, 'and starting with the host' );
    is( $state->{files}{$ACL}, 'allow virbr1', 'the account may join its bridge' );
    like( $state->{files}{$BRIDGES}, qr{\Aallow[ ]br0\ninclude[ ]\Q$ACL\E\z}, 'through an include, after what bridge.conf had' );
    like( $said,                     qr/Done:[ ]5[ ]step/,                    'every step ran' );

    my @root = @{ $state->{root} };
    ( $rc, $said ) = run_tool( $state, @run );
    is( $rc, 0, 'a second run exits 0' );
    like( $said, qr/Done:[ ]0[ ]step/, 'and finds nothing to do' );
    is( $state->{defined}, 1, 'the network was defined once' );
    is( $state->{started}, 1, 'and started once' );
    is_deeply( $state->{root}, \@root, 'and nothing more ran as root' );
};

subtest 'the bridge of a runner account stays allowed, and the network is defined again under its uuid' => sub {
    my $state = fresh_state();
    $state->{files}{$ACL} = "allow virbr0\nallow br0";
    $state->{networks}{clod} = { xml => "<network><name>clod</name><uuid>u-old</uuid><forward mode='nat'/><bridge name='virbr1'/><ip address='10.0.0.1' prefix='16'/></network>", active => 1, autostart => 1 };

    my ( undef, $said ) = run_tool( $state, @run );
    is( $state->{files}{$ACL}, "allow virbr0\nallow br0\nallow virbr1", 'the bridges of bin/runner_account are still there, and the new one after them' );
    like( $state->{networks}{clod}{xml}, qr{<uuid>u-old</uuid>.*prefix='24'},           'a network with another prefix is defined with the one of the plan, under the uuid it had' );
    like( $said,                         qr/net-destroy[ ]clod[ ]&&.*net-start[ ]clod/, 'and since it runs, it says how to restart it, which it does not do itself' );
    is( $state->{started}, 0, 'so it is not restarted' );
};

subtest 'what it refuses to make' => sub {
    my $state = fresh_state();

    like( exception { run_tool( $state, qw{--hypervisor clod},             '--hvconf', hvconf() ) },                                              qr/session[ ]URI.*--via/,                               'a session block with no account on the system URI to act through' );
    like( exception { run_tool( $state, qw{--hypervisor clod --via other}, '--hvconf', hvconf() ) },                                              qr/--via[ ]names[ ]a[ ]block[ ]of[ ]the[ ]same[ ]host/, 'an account of another host' );
    like( exception { run_tool( $state, @run[ 0 .. 3 ],                    '--hvconf', hvconf( pool_cidr => '10.0.1.0/26' ) ) },                  qr{10[.]0[.]1[.]0/26[ ]outside[ ]10[.]0[.]0[.]0/24},    'a pool outside the network' );
    like( exception { run_tool( $state, @run[ 0 .. 3 ],                    '--hvconf', hvconf( network => q{} ) ) },                              qr/--name/,                                             'a block that names no network, without --name' );
    like( exception { run_tool( $state, @run[ 0 .. 3 ],                    '--hvconf', hvconf( gateway => q{} ) ) },                              qr/no[ ]gateway/,                                       'or no gateway' );
    like( exception { run_tool( $state, @run,                              '--name',   'bad name' ) },                                            qr/name[ ]of[ ]a[ ]guest[ ]network/,                    'a name libvirt would not take' );
    like( exception { run_tool( $state, @run[ 0 .. 3 ],                    '--hvconf', hvconf( bridge_device => 'virbr0', nics => 'virbr0' ) ) }, qr/virbr0/,                                             'a block whose bridge is the NAT one' );

    $state->{networks}{other} = { xml => "<network><name>other</name><bridge name='virbr1'/></network>", active => 1, autostart => 1 };
    like( exception { run_tool( $state, @run ) }, qr/virbr1[ ]on[ ].*belongs[ ]to[ ]the[ ]network[ ]other/, 'and a bridge that another network has' );
    is( $state->{defined}, 0, 'none of which defines anything' );
};

done_testing();
