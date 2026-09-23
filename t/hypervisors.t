#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/hypervisors.t - Trog::Hypervisors: reading the fleet, and placing a guest in it

=cut

use Test::More;
use Capture::Tiny qw{capture_stdout};
use Test::Fatal   qw{exception};
use File::Temp    qw{tempdir};
use File::Slurper::Temp();
use Test::MockModule qw{strict};
use Config::Simple();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo
use Trog::HV();

# Loaded so Test::MockModule has a package to attach to: Trog::HV requires its
# backend lazily, and it is named only as a string below.
use Trog::HV::Libvirt();      ## no critic (ProhibitUnusedImports)
use Trog::HV::OpenStack();    ## no critic (ProhibitUnusedImports)
use Trog::Hypervisors();

my $GB = 1024 * 1024 * 1024;

# A hypervisors.conf with two machines in it.
sub fleet_file {
    my (%extra) = @_;
    $extra{$_} //= '' for qw{hv1 hv2};
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/hypervisors.conf", <<"CONF" );
[hv1]
libvirt_uri=qemu+ssh://root\@hv1.example.test/system
bridge_device=br0
reserve_memory=4096
max_guests=20
$extra{hv1}

[hv2]
libvirt_uri=qemu+ssh://root\@hv2.example.test/system
$extra{hv2}
CONF
    return "$dir/hypervisors.conf";
}

# A hypervisors.conf with whatever blocks the caller wants, for the tests about
# what makes a block one kind of hypervisor rather than the other.
sub fleet_of {
    my ($body) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/hypervisors.conf", $body );
    return "$dir/hypervisors.conf";
}

sub guest_conf {
    my (%params) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/provision.conf", join( '', map { "$_=$params{$_}\n" } sort keys %params ) );
    return Config::Simple->new("$dir/provision.conf");
}

# Capacity comes from libvirt, so hand Trog::HV a made-up one.
sub with_capacity {
    my (%by_name) = @_;
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine(
        capacity => sub {
            my ($self) = @_;
            my $c      = $by_name{ $self->name // 'local' }
              or die "no capacity configured for " . ( $self->name // 'local' ) . "\n";
            die "$c\n" if !ref $c;    # a string stands for an unreachable machine
            return $c;
        }
    );
    return $mock;
}

# place() reports what it chose; tests don't need to see it.
sub quietly {
    my ($code) = @_;
    my ( undef, @result ) = capture_stdout { $code->() };
    return wantarray ? @result : $result[0];
}

sub capacity {
    my (%o) = @_;
    return {
        memory_mb        => $o{memory_mb}        // 65536,
        memory_committed => $o{memory_committed} // 0,
        memory_free      => $o{memory_free}      // 32768,
        cpus             => $o{cpus}             // 16,
        cpus_allocatable => $o{cpus_allocatable} // 64,
        cpus_committed   => $o{cpus_committed}   // 0,
        cpus_free        => $o{cpus_free}        // 32,
        disk_free        => $o{disk_free}        // 500 * $GB,
        guests           => $o{guests}           // 3,
    };
}

# --- Reading the file ---------------------------------------------------------
subtest 'no hypervisors.conf means no fleet' => sub {
    my $fleet = Trog::Hypervisors->load('/tmp/nonexistent_xyz/hypervisors.conf');
    ok( !$fleet->configured, 'not configured' );
    is_deeply( [ $fleet->names ], [], 'and it names nobody' );

    ok( !Trog::Hypervisors->load(undef)->configured, 'an undef path is the same thing' );
};

subtest 'a fleet is read in file order' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );
    ok( $fleet->configured, 'configured' );
    is_deeply( [ $fleet->names ], [qw{hv1 hv2}], 'both, in order' );

    my $hv1 = $fleet->hypervisor('hv1');
    is( $hv1->name,           'hv1',                                     'name' );
    is( $hv1->uri,            'qemu+ssh://root@hv1.example.test/system', 'uri' );
    is( $hv1->bridge_device,  'br0',                                     'bridge_device, so no probing' );
    is( $hv1->reserve_memory, 4096,                                      'reserve_memory' );
    is( $hv1->max_guests,     20,                                        'max_guests' );

    is( $fleet->hypervisor('hv2')->reserve_memory, 2048, 'unset limits fall back to the defaults' );
    is( $fleet->hypervisor('hv2')->cpu_overcommit, 4,    'including the cpu overcommit ratio' );

    is( $fleet->hypervisor('hv1'), $hv1, 'built once and kept' );
};

subtest 'a name the file does not have is an error' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );
    my $err   = exception { $fleet->hypervisor('hv3') };
    like( $err, qr/No[ ]hypervisor[ ]named[ ]'hv3'/, 'dies' );
    like( $err, qr/hv1,[ ]hv2/,                      'and says what there is' );
};

subtest 'a file with no blocks is an error' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/hypervisors.conf", "libvirt_uri=qemu:///system\n" );
    like( exception { Trog::Hypervisors->load("$dir/hypervisors.conf") }, qr/names[ ]no[ ]hypervisors/, 'dies rather than silently finding nothing' );
};

# --- Finding a guest that already exists -------------------------------------
subtest 'hosting asks each hypervisor' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists => sub { $_[0]->name eq 'hv2' ? 1 : 0 } );

    my $found = $fleet->hosting('vm.example.test');
    is( $found && $found->name, 'hv2', 'the one that has it' );

    $mock->redefine( domain_exists => sub { 0 } );
    is( $fleet->hosting('vm.example.test'), undef, 'undef when nobody does' );
};

subtest 'an unreachable hypervisor is warned about, not fatal' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine(
        domain_exists => sub {
            die "connection refused\n" if $_[0]->name eq 'hv1';
            return 1;
        }
    );

    my @warnings;
    my $found = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $fleet->hosting('vm.example.test');
    };

    is( $found && $found->name, 'hv2', 'the reachable one still answers' );
    like( join( '', @warnings ), qr/hv1/,                  'and we said which one we could not ask' );
    like( join( '', @warnings ), qr/connection[ ]refused/, 'including why' );
};

subtest 'must_answer: nowhere is only an answer when everywhere answered' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );
    local $SIG{__WARN__} = sub { };

    my %has;
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists => sub { my $answer = $has{ $_[0]->name }; die "$answer\n" if $answer =~ m/[[:alpha:]]/; return $answer } );

    %has = ( hv1 => 'locked', hv2 => 1 );
    is( $fleet->hosting( 'vm.example.test', must_answer => 1 )->name, 'hv2', 'one that has it is found, whatever another could not say' );

    %has = ( hv1 => 'locked', hv2 => 0 );
    is( $fleet->hosting('vm.example.test'), undef, 'without must_answer, one that could not say is taken not to have it' );
    my $err = exception { $fleet->hosting( 'vm.example.test', must_answer => 1 ) };
    like( $err, qr/Could[ ]not[ ]ask[ ]every[ ]hypervisor/, 'with it, that is not an answer' );
    like( $err, qr/hv1:[ ]locked/,                          'naming the one, and why' );

    %has = ( hv1 => 0, hv2 => 0 );
    is( $fleet->hosting( 'vm.example.test', must_answer => 1 ), undef, 'and when everywhere says no, it is nowhere' );

    local $ENV{TROG_PROVISIONER_CONFIG} = File::Basename::dirname( fleet_file() );
    is( Trog::Hypervisors->find( 'vm.example.test', hvconf => fleet_file(), missing_ok => 1 ), undef, 'find says nowhere with missing_ok' );
    like( exception { Trog::Hypervisors->find( 'vm.example.test', hvconf => fleet_file() ) }, qr/No[ ]hypervisor[ ]in/, 'and dies without it, as it did' );
};

# --- Placement ----------------------------------------------------------------
subtest 'place picks the roomiest that fits' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );
    my $mock  = with_capacity(
        hv1 => capacity( memory_free => 8192,  disk_free => 100 * $GB ),
        hv2 => capacity( memory_free => 40000, disk_free => 900 * $GB ),
    );

    my $chosen = quietly( sub { $fleet->place( 'vm.example.test', memory_mb => 4096, cpus => 2, disk_bytes => 40 * $GB ) } );
    is( $chosen->name, 'hv2', 'the emptier one' );
};

subtest 'placement is by the tightest resource, not the roomiest' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );

    # hv1 has more memory free; hv2 has far more disk.  A guest wanting a big
    # disk belongs on hv2 even though hv1 looks better on RAM alone.
    my $mock = with_capacity(
        hv1 => capacity( memory_free => 60000, memory_mb => 65536, disk_free => 60 * $GB ),
        hv2 => capacity( memory_free => 20000, memory_mb => 65536, disk_free => 4000 * $GB ),
    );

    my $chosen = quietly( sub { $fleet->place( 'big.example.test', memory_mb => 4096, cpus => 2, disk_bytes => 50 * $GB ) } );
    is( $chosen->name, 'hv2', 'the one that will not be nearly full afterwards' );
};

subtest 'place picks the cheapest that fits, before the roomiest' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );
    my $room  = with_capacity(
        hv1 => capacity( memory_free => 8192 ),
        hv2 => capacity( memory_free => 40000 ),
    );

    my %price = ( hv1 => 0, hv2 => 0 );
    my $cost  = Test::MockModule->new('Trog::HV::Libvirt');
    $cost->redefine( monthly_cost => sub { my ($self) = @_; my $p = $price{ $self->name }; die "$p\n" if $p =~ m/[[:alpha:]]/; return $p } );

    my %needs = ( memory_mb => 4096, cpus => 2, disk_bytes => 40 * $GB );

    $price{hv2} = 12;
    my ( $out, $chosen ) = capture_stdout { $fleet->place( 'vm.example.test', %needs ) };
    is( $chosen->name, 'hv1', 'one that costs nothing, though it is fuller, over one that bills for the guest' );
    like( $out, qr/the[ ]roomiest[ ]of[ ]those[ ]that[ ]cost[ ]nothing[ ]more/, 'saying why' );

    %price = ( hv1 => 24, hv2 => 12 );
    ( $out, $chosen ) = capture_stdout { $fleet->place( 'vm.example.test', %needs ) };
    is( $chosen->name, 'hv2', 'of two that bill, the cheaper' );
    like( $out, qr/the[ ]cheapest[ ]at[ ]12[.]00[ ]a[ ]month/, 'saying what it costs' );

    %price = ( hv1 => 12, hv2 => 12 );
    is( quietly( sub { $fleet->place( 'vm.example.test', %needs ) } )->name, 'hv2', 'and of two that cost the same, the roomier' );

    %price = ( hv1 => 0, hv2 => 'no price for that type' );
    my $err = exception { $fleet->place( 'vm.example.test', %needs, memory_mb => 16384 ) };
    like( $err, qr/hv2:[ ]unreachable[ ]--[ ]no[ ]price[ ]for[ ]that[ ]type/, 'one that cannot say what the guest would cost is not placed on, and says why' );
};

subtest 'nowhere to put it is an error that says why' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );
    my $mock  = with_capacity(
        hv1 => capacity( memory_free => 512, guests    => 20 ),
        hv2 => capacity( memory_free => 512, disk_free => 1 * $GB ),
    );

    my $err = exception { $fleet->place( 'vm.example.test', memory_mb => 8192, cpus => 2, disk_bytes => 40 * $GB ) };
    like( $err, qr/Nowhere[ ]to[ ]put[ ]vm\.example\.test/,              'refuses' );
    like( $err, qr/hv1:[ ]needs[ ]8192MB[ ]of[ ]memory,[ ]512MB[ ]free/, 'naming what hv1 was short of' );
    like( $err, qr/hv1:[ ]already[ ]has[ ]20[ ]guests/,                  'and that it is full' );
    like( $err, qr/hv2:[ ]needs[ ]40GB[ ]of[ ]disk/,                     'and what hv2 was short of' );
};

subtest 'an unreachable hypervisor is reported as such, not skipped silently' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );
    my $mock  = with_capacity( hv1 => 'libvirt says no', hv2 => capacity( memory_free => 512 ) );

    like( exception { $fleet->place( 'vm.example.test', memory_mb => 8192, cpus => 2, disk_bytes => 1 * $GB ) }, qr/hv1:[ ]unreachable[ ]--[ ]libvirt[ ]says[ ]no/, 'named, with the reason' );
};

# --- select_for ---------------------------------------------------------------
subtest 'a guest that already exists stays where it is' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists => sub { $_[0]->name eq 'hv1' ? 1 : 0 } );
    $mock->redefine( capacity      => sub { die "placement should not have been asked\n" } );

    my $hv = quietly( sub { $fleet->select_for( 'vm.example.test', guest_conf( memory => 4096, cpus => 2, size => 40 * $GB ) ) } );
    is( $hv->name,             'hv1', 'found rather than placed' );
    is( Trog::HV->new()->name, 'hv1', 'and it became the current hypervisor' );
};

subtest 'provision.conf can pin a guest to a hypervisor' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists => sub { 0 } );
    $mock->redefine( capacity      => sub { capacity() } );

    my $conf = guest_conf( memory => 4096, cpus => 2, size => 40 * $GB, hypervisor => 'hv2' );
    my $hv   = $fleet->select_for( 'vm.example.test', $conf );
    is( $hv->name, 'hv2', 'pinned where it was told' );
};

subtest 'a pin to a hypervisor that cannot take it is an error' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists => sub { 0 } );
    $mock->redefine( capacity      => sub { capacity( memory_free => 128 ) } );

    my $conf = guest_conf( memory => 4096, cpus => 2, size => 40 * $GB, hypervisor => 'hv2' );
    my $err  = exception { $fleet->select_for( 'vm.example.test', $conf ) };
    like( $err, qr/pinned[ ]to[ ]hv2,[ ]which[ ]cannot[ ]take[ ]it/, 'refuses rather than placing it elsewhere' );
    like( $err, qr/needs[ ]4096MB[ ]of[ ]memory/,                    'and says what it was short of' );
};

# --- find ---------------------------------------------------------------------
subtest 'when nothing has room, what a hypervisor would sell is offered' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_of(<<'CONF') );
[hv1]
libvirt_uri=qemu+ssh://root@hv1.example.net/system

[linode1]
linode_token=secret:linode/api/password
region=us-east
CONF

    # The machine is full, and Linode would sell something that holds it.
    my $room   = with_capacity( hv1 => capacity( memory_free => 512 ) );
    my $linode = Test::MockModule->new('Trog::HV::Linode');

    # As the real one does: a guest that names no type is not built there, and
    # one that names it is measured against it.
    $linode->redefine( shortfalls   => sub { my ( undef, %needs ) = @_; return $needs{linode_type} ? () : 'names no linode_type, so it is not built on Linode' } );
    $linode->redefine( cheapest_for => sub { return { key => 'linode_type', value => 'g6-standard-2', monthly_cost => 24 } } );

    my $local = Test::MockModule->new('Trog::Local');
    my ( $asked, $answer );
    my $utils = Test::MockModule->new('Trog::Utils');
    $utils->redefine( prompt => sub { $asked = shift; return $answer } );

    my $written;
    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( record_global => sub { my ( undef, @args ) = @_; $written = \@args; return '/bogus/recipes.d/vm.test.test.yaml' } );

    # Nobody to answer: the offer is the error, so a cron or a button gets it.
    $local->redefine( interactive => sub { 0 } );
    my $config = { memory => 8192, cpus => 2, size => 40 * $GB };
    my $err    = exception { $fleet->select_for( 'vm.test.test', $config ) };
    like $err, qr/Nothing[ ]in[ ]\N*has[ ]room[ ]for[ ]vm[.]test[.]test/, 'it says nothing had room';
    like $err, qr/linode1[ ]would[ ]build[ ]it[ ]as[ ]a[ ]g6-standard-2/, 'what it would be';
    like $err, qr/at[ ]24[.]00[ ]a[ ]month/,                              'and what that costs';
    like $err, qr/linode_type:[ ]g6-standard-2/,                          'and the line to write to accept it';
    like $err, qr/hv1:[ ]needs/,                                          'with what each hypervisor lacked still in there';
    is $written, undef, 'nothing was written, and nothing was built';

    # A type billed by the hour has no monthly price to be capped at, so the
    # figure is hours of the rate and the offer says as much.
    $linode->redefine( cheapest_for => sub { return { key => 'linode_type', value => 'g1-gpu-rtx6000-1', monthly_cost => 1095, hourly => 1.5 } } );
    $err = exception { $fleet->select_for( 'vm.test.test', $config ) };
    like $err, qr/at[ ]1095[.]00[ ]a[ ]month/,           'the month it works out to';
    like $err, qr/billed[ ]at[ ]1[.]5[ ]an[ ]hour/,      'and the hourly rate it comes from';
    like $err, qr/no[ ]monthly[ ]price[ ]to[ ]cap[ ]it/, 'and that nothing caps it';
    $linode->redefine( cheapest_for => sub { return { key => 'linode_type', value => 'g6-standard-2', monthly_cost => 24 } } );

    # Somebody to answer, who says no.
    $local->redefine( interactive => sub { 1 } );
    $answer = 'n';
    $err    = exception {
        quietly( sub { $fleet->select_for( 'vm.test.test', $config ) } )
    };
    like $asked, qr/Build[ ]vm\.test\.test[ ]there/, 'it asks';
    like $err,   qr/Declined/,                       'and a no is a no';
    is $written, undef, 'with nothing written';

    # And who says yes.
    $answer = 'y';
    my $chosen = quietly( sub { $fleet->select_for( 'vm.test.test', $config ) } );
    is $chosen->name, 'linode1', 'a yes places the guest where the offer was';
    is_deeply $written, [qw{vm.test.test linode_type g6-standard-2}], 'the size is written into the file of the domain, so the next run does not ask';
    is $config->{linode_type}, 'g6-standard-2', 'and into what this run is generating from, which was read before that';
};

subtest 'an offer that would then be refused is not taken' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_of(<<'CONF') );
[hv1]
libvirt_uri=qemu+ssh://root@hv1.example.net/system

[linode1]
linode_token=secret:linode/api/password
region=us-east
CONF

    my $room   = with_capacity( hv1 => capacity( memory_free => 512 ) );
    my $linode = Test::MockModule->new('Trog::HV::Linode');

    # A backend that offers something its own limits refuse would be built on,
    # and the refusal would come from the API after somebody agreed to pay.
    $linode->redefine( cheapest_for => sub { return { key => 'linode_type', value => 'g6-standard-2', monthly_cost => 24 } } );
    $linode->redefine( shortfalls   => sub { return 'a g6-standard-2 costs more than the account has left' } );

    my $local = Test::MockModule->new('Trog::Local');
    $local->redefine( interactive => sub { 1 } );
    my $utils = Test::MockModule->new('Trog::Utils');
    $utils->redefine( prompt => sub { return 'y' } );

    my $written;
    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( record_global => sub { $written = 1; return '/bogus' } );

    my $err = exception {
        quietly( sub { $fleet->select_for( 'vm.test.test', { memory => 8192, cpus => 2, size => 40 * $GB } ) } )
    };
    like $err, qr/offered[ ]a[ ]g6-standard-2/,                      'the offer is checked against the hypervisor that made it';
    like $err, qr/then[ ]would[ ]not[ ]take[ ]it/,                   'which is what the second look is for';
    like $err, qr/costs[ ]more[ ]than[ ]the[ ]account[ ]has[ ]left/, 'saying what it said the second time';
    is $written, undef, 'and nothing was written for a size that does not fit';
};

subtest 'an offer nobody can make is the shortfall, not an offer' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_file() );
    my $room  = with_capacity( hv1 => capacity( memory_free => 512 ), hv2 => capacity( memory_free => 512 ) );

    my $local = Test::MockModule->new('Trog::Local');
    $local->redefine( interactive => sub { 1 } );

    my $err = exception { $fleet->select_for( 'vm.test.test', { memory => 8192, cpus => 2, size => 40 * $GB } ) };
    like $err,   qr/Nowhere[ ]to[ ]put[ ]vm\.test\.test/, 'a fleet of machines alone says what it always said';
    unlike $err, qr/would[ ]build/,                       'and offers nothing, because nothing there sells anything';
};

subtest 'find' => sub {
    my $path = fleet_file();

    Trog::HV->forget();
    my $named = Trog::Hypervisors->find(
        'vm.example.test',
        hypervisor => 'hv2', hvconf => $path
    );
    is( $named->name,        'hv2', '--hypervisor names one, and no guest is searched for' );
    is( Trog::HV->new->name, 'hv2', 'and it became the current hypervisor' );

    Trog::HV->forget();
    my $unknown = exception { Trog::Hypervisors->find( 'vm.example.test', hypervisor => 'hv9', hvconf => $path ) };
    like( $unknown, qr/No[ ]hypervisor[ ]named[ ]'hv9'/, 'a name the file does not have stops it' );
    like( $unknown, qr/it[ ]has:[ ]hv1,[ ]hv2/,          'and says which names it does have' );

    Trog::HV->forget();
    like(
        exception { Trog::Hypervisors->find( 'vm.example.test', hypervisor => 'hv1', hvconf => '/tmp/nonexistent_xyz/hypervisors.conf' ) },
        qr/No[ ]hypervisors[ ]are[ ]configured/,
        'and naming one where there is no fleet is refused rather than falling back to this machine'
    );

    Trog::HV->forget();
    my $no_fleet = Trog::Hypervisors->find(
        'vm.example.test',
        hvconf => '/tmp/nonexistent_xyz/hypervisors.conf', config => undef
    );
    ok( $no_fleet->is_local, 'with no fleet we are back to the local hypervisor' );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists => sub { $_[0]->name eq 'hv2' ? 1 : 0 } );

    Trog::HV->forget();
    my $found = quietly( sub { Trog::Hypervisors->find( 'vm.example.test', hvconf => $path ) } );
    is( $found->name, 'hv2', 'found on the one that has it' );

    $mock->redefine( domain_exists => sub { 0 } );
    Trog::HV->forget();
    my $err = exception { Trog::Hypervisors->find( 'gone.example.test', hvconf => $path ) };
    like( $err, qr/has[ ]a[ ]guest[ ]called[ ]gone\.example\.test/, 'a guest on none of them is an error' );
    like( $err, qr/Looked[ ]on:[ ]hv1,[ ]hv2/,                      'saying where we looked' );
};

# --- choose -------------------------------------------------------------------
subtest 'choose' => sub {
    my $path = fleet_file();

    Trog::HV->forget();
    my $named = Trog::Hypervisors->choose(
        'vm.example.test',
        hypervisor => 'hv2',
        hvconf     => $path,
        domain_dir => '/bogus/domains',
    );
    is( $named->name,       'hv2',            '--hypervisor names one, and nothing is placed' );
    is( $named->domain_dir, '/bogus/domains', 'and keeps the domain directory it was given' );

    Trog::HV->forget();
    my $no_fleet = Trog::Hypervisors->choose(
        'vm.example.test',
        hvconf => '/bogus/nonexistent/hypervisors.conf',
        config => guest_conf( libvirt_uri => 'qemu+ssh://root@confhv/system' ),
    );
    is( $no_fleet->uri, 'qemu+ssh://root@confhv/system', 'with no fleet, the configuration of the guest names it' );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists => sub { $_[0]->name eq 'hv2' && $_[1] eq 'host.example.test' ? 1 : 0 } );
    $mock->redefine( capacity      => sub { capacity() } );

    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };

    Trog::HV->forget();
    my $placed = quietly(
        sub {
            Trog::Hypervisors->choose(
                'vm.example.test',
                hvconf     => $path,
                domain_dir => '/bogus/domains',
                config     => guest_conf( memory => 4096, cpus => 2, size => 40 * $GB, libvirt_uri => 'qemu+ssh://root@confhv/system' ),
            );
        }
    );
    is( $placed->name,         'hv1',            'a new guest is placed in the fleet' );
    is( $placed->domain_dir,   '/bogus/domains', 'and a domain directory that was given wins over the fleet' );
    is( Trog::HV->new()->name, 'hv1',            'and it became the current hypervisor' );
    like( "@warned", qr/libvirt_uri[ ]in[ ]its[ ]configuration[ ]is[ ]ignored/, 'a libvirt_uri that the fleet overrides is warned about' );

    # hv1 is current now.  A second guest is chosen for all the same, rather
    # than handed the one that the first guest got.
    my $tenant = quietly(
        sub {
            Trog::Hypervisors->choose(
                'tenant.example.test',
                hvconf      => $path,
                config      => guest_conf( memory => 4096, cpus => 2, size => 40 * $GB ),
                host        => 'host.example.test',
                host_config => guest_conf( memory => 8192, cpus => 4, size => 40 * $GB ),
            );
        }
    );
    is( $tenant->name, 'hv2', 'a tenant goes where its host is, and not where the last guest went' );
};

# --- Capacity arithmetic, against a stand-in libvirt --------------------------
subtest 'capacity counts what is committed, not what is used' => sub {
    Trog::HV->forget();
    my $hv = Trog::HV->candidate( uri => 'qemu+ssh://hv/system', name => 'hv1', reserve_memory => 2048, reserve_cpus => 2 );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( vmm       => sub { FakeVMM->new() } );
    $mock->redefine( pool_free => sub { 200 * $GB } );

    my $have = $hv->capacity;
    is( $have->{memory_mb},        32768,                'physical memory in MB' );
    is( $have->{memory_committed}, 12288,                'the sum of what guests may grow into, idle or not' );
    is( $have->{memory_free},      32768 - 12288 - 2048, 'free is physical less committed less the reserve' );
    is( $have->{cpus},             8,                    'physical CPUs' );
    is( $have->{cpus_allocatable}, 32,                   'times the overcommit ratio' );
    is( $have->{cpus_committed},   6,                    'vCPUs of running guests only' );
    is( $have->{cpus_free},        32 - 6 - 2,           'free CPUs after the reserve' );
    is( $have->{guests},           3,                    'domains, running or not' );

    is( $hv->capacity, $have, 'cached, so we ask libvirt once' );
};

subtest 'shortfalls and headroom' => sub {
    Trog::HV->forget();
    my $hv = Trog::HV->candidate( uri => 'qemu+ssh://hv/system', name => 'hv1' );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( capacity => sub { capacity( memory_free => 8192, cpus_free => 4, disk_free => 100 * $GB ) } );

    is_deeply(
        [ $hv->shortfalls( memory_mb => 4096, cpus => 2, disk_bytes => 50 * $GB ) ], [],
        'a guest that fits has nothing wrong with it'
    );

    my @reasons = $hv->shortfalls( memory_mb => 99999, cpus => 99, disk_bytes => 900 * $GB );
    is( scalar @reasons, 3, 'one reason per resource it is short of' );
    like( $reasons[0], qr/memory/, 'memory' );
    like( $reasons[1], qr/vCPUs/,  'cpus' );
    like( $reasons[2], qr/disk/,   'disk' );

    my $roomy = $hv->headroom( memory_mb => 1,    cpus => 1, disk_bytes => 1 * $GB );
    my $snug  = $hv->headroom( memory_mb => 8000, cpus => 4, disk_bytes => 99 * $GB );
    cmp_ok( $roomy, '>',  $snug, 'a small guest leaves more headroom than one that just fits' );
    cmp_ok( $snug,  '>=', 0,     'and headroom never goes negative' );
};

# A stand-in for a libvirt connection.
{

    package FakeVMM;

    sub new           { return bless {}, shift }
    sub get_node_info { return { memory => 32768 * 1024, cpus => 8, model => 'x86_64' } }

    sub list_all_domains {
        return (
            FakeDomain->new( maxMem => 4096 * 1024, nrVirtCpu => 2, active => 1 ),
            FakeDomain->new( maxMem => 4096 * 1024, nrVirtCpu => 4, active => 1 ),

            # Shut off, so its memory is still committed but its vCPUs are not.
            FakeDomain->new( maxMem => 4096 * 1024, nrVirtCpu => 8, active => 0 ),
        );
    }
}

{

    package FakeDomain;

    sub new               { my ( $class, %o ) = @_; return bless {%o}, $class }
    sub get_info          { my ($s) = @_; return { maxMem => $s->{maxMem}, nrVirtCpu => $s->{nrVirtCpu} } }
    sub is_active ($self) { return $self->{active} }
}

subtest 'file order is the file\'s order, not the alphabet\'s' => sub {

    # Named so that alphabetical and file order disagree.  With hv1/hv2/hv3 the
    # two are the same, which is how sorting the keys passed for file order.
    my $fleet = Trog::Hypervisors->load( fleet_of(<<'CONF') );
[zulu]
libvirt_uri=qemu+ssh://root@zulu.example.net/system

[alpha]
libvirt_uri=qemu+ssh://root@alpha.example.net/system

[mike]
libvirt_uri=qemu+ssh://root@mike.example.net/system
CONF

    is_deeply [ $fleet->names ], [qw{zulu alpha mike}],
      'the order the file lists them in, which is what the documentation promises';
};

subtest 'a block naming a cloud is an OpenStack hypervisor' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_of(<<'CONF') );
[hv1]
libvirt_uri=qemu+ssh://root@hv1.example.net/system

[cloud1]
cloud=openstack
network=internal
floating_network=public
reserve_memory=8192
CONF

    is_deeply [ $fleet->names ], [qw{hv1 cloud1}], 'both kinds live in one file';

    is ref $fleet->hypervisor('hv1'), 'Trog::HV::Libvirt', 'the one with a URI is libvirt';

    my $os = $fleet->hypervisor('cloud1');
    is ref $os,               'Trog::HV::OpenStack', 'and the one with a cloud is not';
    is $os->name,             'cloud1',              'named as the file names it';
    is $os->cloud,            'openstack',           'pointed at the clouds.yaml entry';
    is $os->network,          'internal',            'the network';
    is $os->floating_network, 'public',              'and where floating IPs come from';

    is $os->reserve_memory, 8192,
      'the limits are read the same way for either kind, because placement is shared';
};

subtest 'a block naming a linode_token is a Linode hypervisor' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_of(<<'CONF') );
[linode1]
linode_token=secret:linode/api/password
region=us-east
monthly_budget=200
max_guests=10
CONF

    my $linode = $fleet->hypervisor('linode1');
    is ref $linode,             'Trog::HV::Linode', 'the one with a token is Linode';
    is $linode->name,           'linode1',          'named as the file names it';
    is $linode->region,         'us-east',          'in its region';
    is $linode->monthly_budget, 200,                'within its budget';
    is $linode->max_guests,     10,                 'and the limits are read as for any kind';
};

subtest 'any block can say where its guests reach us' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_of(<<'CONF') );
[hv1]
libvirt_uri=qemu+ssh://root@hv1.example.net/system

[far]
libvirt_uri=qemu+ssh://root@far.example.net/system
transfer_ip=192.0.2.10
transfer_port=2222

[typo]
libvirt_uri=qemu+ssh://root@typo.example.net/system
transfer_port=ssh
CONF

    is $fleet->hypervisor('hv1')->configured_transfer_ip,   undef,        'a block that does not say leaves it to _global and the routing table';
    is $fleet->hypervisor('hv1')->configured_transfer_port, undef,        'port included';
    is $fleet->hypervisor('far')->configured_transfer_ip,   '192.0.2.10', 'one that does, says the address';
    is $fleet->hypervisor('far')->configured_transfer_port, 2222,         'and the port';

    like exception { $fleet->hypervisor('typo')->configured_transfer_port }, qr/transfer_port[ ]for[ ]typo[ ]is[ ]'ssh'/, 'and a port that is not one is said, naming the block';
};

subtest 'the documented example is a file that loads' => sub {

    # The shipped example, not a copy of it.  A configuration file people are
    # told to copy and edit is documentation that can go stale silently, and the
    # only thing that stops it is reading the real one.
    my $example = "$FindBin::Bin/../hypervisors.conf.example";

    my $fleet = Trog::Hypervisors->load($example);
    ok $fleet->configured, 'the example describes a fleet';

    my %backend = map { $_ => ref $fleet->hypervisor($_) } $fleet->names;

    is $backend{hv1},     'Trog::HV::Libvirt',   'its machine blocks build machines';
    is $backend{cloud1},  'Trog::HV::OpenStack', 'and its cloud block builds a cloud';
    is $backend{linode1}, 'Trog::HV::Linode',    'and its Linode block a Linode account';
};

subtest 'a block has to say which kind of hypervisor it is' => sub {
    my $both = Trog::Hypervisors->load( fleet_of(<<'CONF') );
[confused]
libvirt_uri=qemu:///system
cloud=openstack
CONF

    my $err = exception { $both->hypervisor('confused') };
    like $err, qr/\[confused\]/,                     'the error names the block';
    like $err, qr/has[ ]libvirt_uri[ ]and[ ]cloud;/, 'and what is wrong with it';

    my $neither = Trog::Hypervisors->load( fleet_of(<<'CONF') );
[vague]
reserve_memory=4096
CONF

    $err = exception { $neither->hypervisor('vague') };
    like $err, qr/\[vague\]/,                                        'likewise by name';
    like $err, qr/none[ ]of[ ]libvirt_uri,[ ]cloud,[ ]linode_token/, 'and why, naming the key of each kind';

    # The one that matters: without this check a block naming nothing falls
    # through to libvirt's default connection, which is this machine -- the one
    # placement nobody writing a fleet file intended.
    unlike $err, qr/qemu/, 'rather than quietly placing the guest here';
};

subtest 'a block says what kind of hypervisor it is, before anything builds one' => sub {
    my $fleet = Trog::Hypervisors->load( fleet_of(<<'CONF') );
[machine]
libvirt_uri=qemu+ssh://root@hv1.example.test/system

[cloud]
cloud=openstack

[account]
linode_token=secret:linode/api/password

[both]
libvirt_uri=qemu:///system
cloud=openstack

[neither]
reserve_memory=4096
CONF

    is( $fleet->backend_of('machine'), 'Trog::HV::Libvirt',   'a libvirt_uri is a machine' );
    is( $fleet->backend_of('cloud'),   'Trog::HV::OpenStack', 'a cloud is a cloud' );
    is( $fleet->backend_of('account'), 'Trog::HV::Linode',    'and a token is a Linode account' );

    # Two kinds cannot both be satisfied, and one kind is what the guests of
    # that block get built on.  Neither is this machine by default, which is
    # the one placement nobody writing the file meant.
    like( exception { $fleet->backend_of('both') },    qr/\[both\][ ]in[ ].*[ ]has[ ]libvirt_uri[ ]and[ ]cloud;[ ]it[ ]can[ ]only[ ]be[ ]one/, 'a block of two kinds is refused, named' );    ## no critic (RegularExpressions::ProhibitComplexRegexes)
    like( exception { $fleet->backend_of('neither') }, qr/\[neither\][ ]in[ ].*[ ]has[ ]none[ ]of[ ].*nothing[ ]to[ ]build[ ]on/,              'and so is a block of none' );                 ## no critic (RegularExpressions::ProhibitComplexRegexes)
    like( exception { $fleet->backend_of('nosuch') },  qr/No[ ]hypervisor[ ]named[ ]'nosuch'/,                                                 'a name the file has not got is said' );

    # It answers without building, so a block whose cloud cannot be reached,
    # or whose client is not installed, still says what it is.
    ok( !$fleet->{built}{cloud}, 'and nothing was built to answer' );
};

done_testing;
