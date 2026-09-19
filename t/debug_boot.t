#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/debug_boot.t - bin/debug_boot: what it refuses, what it rewrites, and the
grub line it edits

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Capture::Tiny    qw{capture capture_stdout};
use Test::MockModule qw{strict};

use File::Temp();
use File::Slurper();
use File::Slurper::Temp();
use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

# Loaded so that blessing into it below blesses into something real, and so
# Test::MockModule in strict mode has methods to find.  The backend rather than
# Trog::HV, because that is where the libvirt methods these mocks replace live,
# and Trog::HV requires it lazily.
use Trog::HV::Libvirt();      ## no critic (ProhibitUnusedImports)
use Trog::HV::OpenStack();    ## no critic (ProhibitUnusedImports) -- the backend whose refusal is under test

my $script = "$FindBin::Bin/../bin/debug_boot";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# How many times one string appears in another, without a regex saying so.
sub count_of {
    my ( $haystack, $needle ) = @_;
    my ( $n,        $at )     = ( 0, 0 );
    $n++ while ( $at = index( $haystack, $needle, $at ) + 1 ) > 0;
    return $n;
}

# What libvirt hands back, near enough: the serial and console it gives a guest,
# and an <os> with no boot menu in it.
sub domain_xml {
    my (%opt) = @_;
    my $serial =
      $opt{file}
      ? "<serial type='file'>\n      <source path='$opt{file}'/>\n      <target type='isa-serial' port='0'/>\n    </serial>"
      : "<serial type='pty'>\n      <target type='isa-serial' port='0'/>\n    </serial>";
    my $menu = $opt{bootmenu} ? "<bootmenu enable='yes' timeout='30000'/>" : q{};

    return <<"XML";
<domain type='kvm'>
  <name>vm.test</name>
  <os>$menu
    <type arch='x86_64' machine='pc'>hvm</type>
  </os>
  <devices>
    $serial
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
</domain>
XML
}

# The actions below drive libvirt through Trog::HV::Libvirt; what is under test
# is what the script does with the XML, so the backend is a place the XML goes
# and comes back from.  domain_definition gives back what was last defined,
# because libvirt does.
sub with_domain {
    my ( $xml, $code ) = @_;

    my %seen = ( defined => undef, restarted => 0 );
    my $hv   = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( domain_definition => sub { $seen{defined} // $xml } );
    $hv->redefine( define_domain     => sub { $seen{defined} = $_[1]; 1 } );
    $hv->redefine( restart_domain    => sub { $seen{restarted}++;     1 } );

    my $bin = Test::MockModule->new( 'Trog::Bin::DebugBoot', no_auto => 1 );
    $code->( \%seen, $bin, $hv );
    return \%seen;
}

subtest 'an action the backend cannot do is refused before the guest is touched' => sub {
    my $hv = Test::MockModule->new('Trog::HV::OpenStack');
    $hv->redefine( describe => sub { 'the OpenStack cloud test' } );
    my $cloud = bless( {}, 'Trog::HV::OpenStack' );

    ok( Trog::Bin::DebugBoot::refuse_unsupported( $cloud, 'console' ), 'an action it can do goes ahead' );

    my $err = exception { Trog::Bin::DebugBoot::refuse_unsupported( $cloud, 'single' ) };
    like( $err, qr/cannot[ ]--single/,              'and one it cannot is refused' );
    like( $err, qr/the[ ]OpenStack[ ]cloud[ ]test/, 'naming the backend' );
    like( $err, qr/--console.*--fetch.*--vnc/,      'and what it can do there' );

    # A backend that says nothing debugs nothing, rather than failing later with
    # an error about libguestfs.
    my $silent = Test::MockModule->new('Trog::HV::Libvirt');
    $silent->redefine( debug_actions => sub { () } );
    $silent->redefine( describe      => sub { 'hv.test' } );
    like(
        exception { Trog::Bin::DebugBoot::refuse_unsupported( bless( {}, 'Trog::HV::Libvirt' ), 'console' ) },
        qr/can[ ]debug[ ]nothing[ ]there/, 'a backend that lists none says so'
    );
};

subtest '--console asks the backend to capture, and says whether it restarted' => sub {
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    my %asked;
    $hv->redefine( console_capture => sub { my ( undef, $name, %o ) = @_; %asked = ( name => $name, %o ); return 1 } );

    my $bin = Test::MockModule->new( 'Trog::Bin::DebugBoot', no_auto => 1 );
    $bin->redefine( fetch => sub { 0 } );

    my ( undef, $err ) = capture { Trog::Bin::DebugBoot::console( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test', { wait => 7 } ) };
    is( $asked{name}, 'vm.test', 'the guest it was given' );
    is( $asked{wait}, 7,         'and how long to let it boot' );
    like( $err, qr/Restarted[ ]it/, 'a backend that restarts the guest says so' );

    $hv->redefine( console_capture => sub { 0 } );
    ( undef, $err ) = capture { Trog::Bin::DebugBoot::console( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test', { wait => 7 } ) };
    like( $err, qr/Nothing[ ]was[ ]restarted/, 'and one that keeps the console says that instead' );
};

subtest '--fetch writes what the backend read, and says when there is none' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    my $hv  = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( console_output => sub { "one\ntwo\nthree\n" } );
    $hv->redefine( describe       => sub { 'hv.test' } );

    my ( $out, undef, $rc ) = capture { Trog::Bin::DebugBoot::fetch( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test', { into => "$dir/console.log" } ) };
    is( $rc,                                          0,                    'it succeeds' );
    is( $out,                                         "$dir/console.log\n", 'and prints the file it wrote' );
    is( File::Slurper::read_text("$dir/console.log"), "one\ntwo\nthree\n",  'which holds what the backend read' );

    $hv->redefine( console_output => sub { undef } );
    my ( undef, $err, $none ) = capture { Trog::Bin::DebugBoot::fetch( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test', {} ) };
    is( $none, 1, 'no console output is a failure' );
    like( $err, qr/No[ ]console[ ]output[ ]for[ ]vm[.]test[ ]on[ ]hv[.]test/, 'naming the guest and where it looked' );
};

subtest '--hold adds a boot menu, once' => sub {
    my $seen = with_domain(
        domain_xml(),
        sub {
            my ( undef, $bin ) = @_;
            $bin->redefine( vnc => sub { 0 } );
            Trog::Bin::DebugBoot::hold( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test', { timeout => 15000 } );
        }
    );

    like( $seen->{defined}, qr{<bootmenu[ ]enable='yes'[ ]timeout='15000'/>}, 'with the timeout asked for' );
    is( $seen->{restarted}, 1, 'and restarted' );

    # Adding a second one would make libvirt reject the whole domain.
    my $again = with_domain(
        domain_xml( bootmenu => 1 ),
        sub {
            my ( undef, $bin ) = @_;
            $bin->redefine( vnc => sub { 0 } );
            Trog::Bin::DebugBoot::hold( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test', { timeout => 15000 } );
        }
    );
    is( count_of( $again->{defined}, '<bootmenu' ), 1, 'never twice' );
};

subtest '--restore undoes both, through what libvirt gives back' => sub {

    # libvirt reformats what it is handed, so the file serial comes back as an
    # element with its source on its own line rather than the one-liner that
    # went in.  Matching the one-liner is how this silently did nothing.
    my $xml = domain_xml( file => '/tmp/vm.test-console.log', bootmenu => 1 );

    my $seen = with_domain(
        $xml,
        sub {
            my ( undef, $bin, $hv ) = @_;
            $bin->redefine( guest_tool => sub { ( q{}, 0 ) } );
            $hv->redefine( vmm => sub { undef } );
            Trog::Bin::DebugBoot::restore( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test' );
        }
    );

    like( $seen->{defined}, qr{<serial[ ]type='pty'>}, 'the serial is a pty again' );
    unlike( $seen->{defined}, qr{<bootmenu}, 'and the boot menu is gone' );
};

# --- The grub edit -------------------------------------------------------------
# virt-edit hands its expression a line with the newline still attached.  A
# trailing \s* eats that, welding the next line on -- which is how this first
# welded grub's initrd directive onto the end of its linux one and left a guest
# with no initrd that did not boot at all.
subtest 'the kernel command line edit leaves the newline alone' => sub {
    my $line = "\tlinux\t/vmlinuz-6.8.0 root=UUID=abc ro  console=ttyS0\n";

    my $add = $line;
    $add =~ s/^([ \t]*linux[ \t]+\S+[^\n]*?)([ \t]+single)?[ \t]*$/$1 single/m;

    like( $add, qr/console=ttyS0[ ]single\n\z/, 'single goes on the end of the line' );
    like( $add, qr/\n\z/,                       'and the newline is still there' );

    $add =~ s/^([ \t]*linux[ \t]+\S+[^\n]*?)([ \t]+single)?[ \t]*$/$1 single/m;
    is( count_of( $add, 'single' ), 1, 'running it twice does not say it twice' );

    my $removed = $add;
    $removed =~ s/^([ \t]*linux[ \t]+[^\n]*?)[ \t]+single[ \t]*$/$1/m;
    is( $removed, $line, 'and taking it off again gives back exactly what we started with' );
};

# libvirt, faked at the level debug_boot talks to it: a connection that finds a
# domain and opens a stream, a domain with a definition and a screen, and a
# stream that hands its bytes over a piece at a time.
{

    package FakeVMM;
    sub new { my ( $class, %fake ) = @_; return bless {%fake}, $class }
    sub get_domain_by_name ( $self, $ ) { return $self->{dom} }
    sub new_stream         ( $self, @ ) { return $self->{stream} }

    package FakeDom;
    sub new { my ( $class, %fake ) = @_; return bless {%fake}, $class }
    sub get_xml_description ( $self, @ ) { return $self->{xml} }
    sub screenshot          ( $self, @ ) { return $self->{mime} }

    package FakeStream;
    sub new { my ( $class, @chunks ) = @_; return bless { chunks => \@chunks, finished => 0 }, $class }

    # Named for what it fakes, Sys::Virt::Stream::recv, which writes into the
    # caller's first argument and returns how much it wrote -- 0 at the end.
    sub recv {    ## no critic (ProhibitBuiltinHomonyms, RequireArgUnpacking) -- a signature copies $_[0], and this has to write through it
        my $self  = shift;
        my $chunk = shift @{ $self->{chunks} };
        return 0 unless defined $chunk;
        $_[0] = $chunk;
        return length $chunk;
    }
    sub finish ($self) { $self->{finished}++; return 1 }
}

sub with_vmm {
    my (%fake) = @_;
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( vmm        => sub { FakeVMM->new(%fake) } );
    $hv->redefine( ssh_target => sub { 'doge@hv.test' } );
    $hv->redefine( describe   => sub { 'hv.test' } );
    return $hv;
}

subtest '--vnc prints what the backend says to act on, and its advice' => sub {
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( vnc_access => sub { ( "tunnel to it like this\n", 5910 ) } );

    my ( $out, $err ) = capture { Trog::Bin::DebugBoot::vnc( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test' ) };
    is( $out, "5910\n",                   'the one thing a caller can act on goes to stdout' );
    is( $err, "tunnel to it like this\n", 'and the advice to the operator goes to stderr' );

    # A cloud hands out a URL instead, and the script prints that the same way.
    $hv->redefine( vnc_access => sub { ( "open this\n", 'https://cloud.test/vnc?token=x' ) } );
    ($out) = capture { Trog::Bin::DebugBoot::vnc( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test' ) };
    is( $out, "https://cloud.test/vnc?token=x\n", 'whatever shape it is' );
};

subtest 'a screenshot is streamed straight here, and named for what it is' => sub {
    my $dir    = File::Temp::tempdir( CLEANUP => 1 );
    my $stream = FakeStream->new( chr(0x89) . 'PNG', 'rest-of-it' );
    my $mock   = with_vmm( dom => FakeDom->new( mime => 'image/png' ), stream => $stream );

    my ($out) = capture_stdout { Trog::Bin::DebugBoot::shot( bless( {}, 'Trog::HV::Libvirt' ), 'vm.test', { into => "$dir/screen" } ) };

    is( $out,                                      "$dir/screen\n",             'the path printed is the one written' );
    is( File::Slurper::read_binary("$dir/screen"), chr(0x89) . 'PNGrest-of-it', 'every piece of the stream, in order' );
    ok( $stream->{finished}, 'and the stream is finished rather than left open' );

    # Measured: qemu on libvirt 10.0.0 sends image/png, which the virsh path
    # this replaced wrote to a file ending .ppm regardless.
    is( Trog::Bin::DebugBoot::screen_file( 'vm.test', 'image/png' ),               '/tmp/vm.test-screen.png', 'a PNG is named .png' );
    is( Trog::Bin::DebugBoot::screen_file( 'vm.test', 'image/x-portable-pixmap' ), '/tmp/vm.test-screen.ppm', 'and a PPM .ppm' );
};

# bin/preflight and this both tell an operator what to install when the tools
# are missing.  Two package names for one fix is one too many.
subtest 'a missing disk tool names the package preflight names' => sub {
    my $mock = with_vmm();
    $mock->redefine( capture_cmd => sub { $? = 127 << 8; return q{} } );    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the caller reads $? after this returns, as it would after a real command
    $mock->redefine( run_cmd     => sub { return 1 } );

    my $hv  = bless( {}, 'Trog::HV::Libvirt' );
    my $err = exception { Trog::Bin::DebugBoot::guest_tool( $hv, qw{virt-cat -d vm.test /etc/hostname} ) };

    my ($package) = $hv->note_libguestfs->{fix} =~ m/apt[ ]install[ ](\S+)/;
    ok( $package, 'preflight names a package' );
    like( $err, qr/apt[ ]install[ ]\Q$package\E\n/, 'and the same one is named here' );
};

# The fleet decides which hypervisor has the guest, as it does for destroy,
# snapshot and restore.  What it finds has to be the current hypervisor too,
# because code under Trog::HV asks Trog::HV->new() for it.
subtest 'the hypervisor that has the guest is found and made current' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/hypervisors.conf", "[hv1]\nlibvirt_uri=qemu+ssh://root\@hv1.test.test/system\n\n[hv2]\nlibvirt_uri=qemu+ssh://root\@hv2.test.test/system\n" );

    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( domain_exists => sub { $_[0]->name eq 'hv2' ? 1 : 0 } );

    Trog::HV->forget();
    my $hv = Trog::Bin::DebugBoot::hypervisor( 'vm.test', undef, "$dir/hypervisors.conf" );
    is( $hv->name,       'hv2', 'the one that has it' );
    is( Trog::HV->new(), $hv,   'and it is the current hypervisor' );

    $mock->redefine( domain_exists => sub { 0 } );
    my $err = exception { Trog::Bin::DebugBoot::hypervisor( 'vm.test', undef, "$dir/hypervisors.conf" ) };
    like( $err, qr/vm[.]test/,        'a guest nothing has is named' );
    like( $err, qr/Pass[ ]--connect/, 'and the way round it is said' );
    Trog::HV->forget();
};

done_testing();
