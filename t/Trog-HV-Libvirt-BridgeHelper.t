#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Trog-HV-Libvirt-BridgeHelper.t - what qemu-bridge-helper reads in its ACL, and which bridges that refuses

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use List::Util();
use File::Basename();
use Capture::Tiny();

use FindBin::libs;
use Trog::Steps();

BEGIN { use_ok('Trog::HV::Libvirt::BridgeHelper') or BAIL_OUT('Trog::HV::Libvirt::BridgeHelper does not load') }

my $CONF = $Trog::HV::Libvirt::BridgeHelper::CONF;

{

    # A hypervisor that has the files of @HAVE, and the text of each file of
    # %FILES, which root reads and writes.
    package Test::HelperHV;
    our @HAVE;
    our %FILES;
    sub new ($class) { return bless {}, $class }

    sub file_exists ( $, $path ) {
        return List::Util::any { $_ eq $path } @HAVE, keys %FILES;
    }

    sub root_text ( $, $path ) { return $FILES{$path} // q{} }

    sub holds_line ( $self, $path, $line ) {
        return List::Util::any { $_ eq $line } split m/\n/, $self->root_text($path);
    }

    sub list_dir ( $, $dir ) {
        return map { m{\A\Q$dir\E/([^/]+)\z} ? $1 : () } sort keys %FILES;
    }

    sub run_sudo_or_die { return 1 }

    sub rewrite_lines ( $self, $path, %how ) {
        my @lines = ( ( grep { $how{keep}->($_) } split m/\n/, $self->root_text($path) ), @{ $how{add} // [] } );
        $FILES{$path} = join q{}, map { "$_\n" } @lines;
        return 1;
    }
}

# A reader of the files of %files, which reads undef for any other path.
sub reader (%files) {
    return sub ($path) { $files{$path} };
}

subtest 'acl_file is the file of one account' => sub {
    is( Trog::HV::Libvirt::BridgeHelper::acl_file('runner'), '/etc/qemu/trog-runner-runner.conf', 'in /etc/qemu, named for the account' );
};

subtest 'helper is the first place that the hypervisor has it' => sub {
    my $hv = Test::HelperHV->new;
    is( Trog::HV::Libvirt::BridgeHelper::helper($hv), undef, 'none, where it is in neither place' );
    @Test::HelperHV::HAVE = ('/usr/libexec/qemu-bridge-helper');
    is( Trog::HV::Libvirt::BridgeHelper::helper($hv), '/usr/libexec/qemu-bridge-helper', 'the second place, where it is only there' );
    @Test::HelperHV::HAVE = @Trog::HV::Libvirt::BridgeHelper::HELPERS;
    is( Trog::HV::Libvirt::BridgeHelper::helper($hv), '/usr/lib/qemu/qemu-bridge-helper', 'and the first, where it is in both' );
};

subtest 'rules reads bridge.conf and each file that it includes' => sub {
    my $rules = Trog::HV::Libvirt::BridgeHelper::rules(
        reader(
            $CONF           => "# the bridges of the host\nallow br0\n\n  include /bogus/a.conf\ndeny virbr9\n",
            '/bogus/a.conf' => "allow virbr0\ninclude /bogus/b.conf\n",
            '/bogus/b.conf' => "allow\tall\n",
        )
    );
    is_deeply(
        $rules,
        [ [ allow => 'br0' ], [ deny => 'virbr9' ], [ allow => 'virbr0' ], [ allow => 'all' ] ],
        'every allow and deny, through two levels of include, and no comment or empty line'
    );
};

subtest 'rules dies where the helper would read something that this cannot' => sub {
    like( exception { Trog::HV::Libvirt::BridgeHelper::rules( reader() ) }, qr{\ACould[ ]not[ ]read[ ]/etc/qemu/bridge[.]conf$}, 'a bridge.conf that it cannot read' );
    like(
        exception { Trog::HV::Libvirt::BridgeHelper::rules( reader( $CONF => "include /bogus/gone.conf\n" ) ) },
        qr{\ACould[ ]not[ ]read[ ]/bogus/gone[.]conf$},
        'and a file that it includes, which the helper would skip'
    );

    my %loop = ( $CONF => "include /bogus/loop.conf\n", '/bogus/loop.conf' => "include /bogus/loop.conf\n" );
    like( exception { Trog::HV::Libvirt::BridgeHelper::rules( reader(%loop) ) }, qr/includes[ ]more[ ]files[ ]than[ ]this[ ]reads/, 'and a loop of includes, which would not end' );

    my %chain = ( $CONF => "include /bogus/1\n", map { ( "/bogus/$_" => "include /bogus/" . ( $_ + 1 ) . "\n" ) } 1 .. 30 );
    $chain{'/bogus/31'} = "allow br0\n";
    is_deeply( Trog::HV::Libvirt::BridgeHelper::rules( reader(%chain) ), [ [ allow => 'br0' ] ], 'but not a chain of 32 files, which is the most that it reads' );
    $chain{'/bogus/31'} = "include /bogus/32\n";
    $chain{'/bogus/32'} = "allow br0\n";
    like( exception { Trog::HV::Libvirt::BridgeHelper::rules( reader(%chain) ) }, qr/includes[ ]more[ ]files/, 'and dies at the 33rd' );
};

subtest 'refused is each bridge that no allow names, or that a deny names' => sub {
    my $rules = [ [ allow => 'br0' ], [ allow => 'virbr0' ], [ deny => 'virbr0' ] ];
    is_deeply( [ Trog::HV::Libvirt::BridgeHelper::refused( $rules,                                    qw{br0 virbr0 virbr1} ) ], [qw{virbr0 virbr1}], 'a deny wins over an allow, and a bridge that nothing names is refused' );
    is_deeply( [ Trog::HV::Libvirt::BridgeHelper::refused( [ [ allow => 'all' ] ],                    qw{br0 virbr1} ) ],        [],                  'allow all lets a user join any bridge' );
    is_deeply( [ Trog::HV::Libvirt::BridgeHelper::refused( [ [ allow => 'all' ], [ deny => 'br0' ] ], qw{br0 virbr1} ) ],        ['br0'],             'except one that a deny names' );
    is_deeply( [ Trog::HV::Libvirt::BridgeHelper::refused( [ [ allow => 'br0' ], [ deny => 'all' ] ], 'br0' ) ],                 ['br0'],             'and deny all refuses each bridge' );
    is_deeply( [ Trog::HV::Libvirt::BridgeHelper::refused( [],                                        'br0' ) ],                 ['br0'],             'with no rules, it refuses everything, as the helper does' );
};

# Runs the actions of @actions, and returns how many changed something.
sub run_quietly (@actions) {
    my $count;
    Capture::Tiny::capture_stdout( sub { $count = Trog::Steps::run( \@actions, 0 ) } );
    return $count;
}

subtest 'allow_only_steps leaves the account its bridges and no other' => sub {
    my $acl = Trog::HV::Libvirt::BridgeHelper::acl_file('runner');
    local %Test::HelperHV::FILES = ( $acl => "allow virbr0\nallow br0\n", $CONF => "allow virbr0\n" );
    my $hv = Test::HelperHV->new;

    ok( run_quietly( Trog::HV::Libvirt::BridgeHelper::allow_only_steps( $hv, 'runner', qw{virbr0 virbr1} ) ), 'a file with another bridge in it is changed' );
    is( $Test::HelperHV::FILES{$acl},                                                                         "allow virbr0\nallow virbr1\n", 'and holds the bridges given, in their order, and not the one it had' );
    is( $Test::HelperHV::FILES{$CONF},                                                                        "allow virbr0\ninclude $acl\n", 'and bridge.conf includes it, after the lines that it had' );
    is( run_quietly( Trog::HV::Libvirt::BridgeHelper::allow_only_steps( $hv, 'runner', qw{virbr0 virbr1} ) ), 0,                              'a second run changes nothing' );

    run_quietly( Trog::HV::Libvirt::BridgeHelper::grant_steps( $hv, 'runner', 'br0' ) );
    is( $Test::HelperHV::FILES{$acl}, "allow virbr0\nallow virbr1\nallow br0\n", 'while grant_steps adds a bridge, and keeps what is there' );
};

subtest 'allowed_by_others names the files of the other accounts that allow a bridge' => sub {
    my $dir = File::Basename::dirname( Trog::HV::Libvirt::BridgeHelper::acl_file('runner') );
    local %Test::HelperHV::FILES = (
        "$dir/trog-runner-runner.conf" => "allow virbr1\n",
        "$dir/trog-runner-b.conf"      => "allow virbr0\nallow virbr1\n",
        "$dir/trog-runner-a.conf"      => "allow virbr1\n",
        "$dir/trog-runner-c.conf"      => "allow virbr10\n",
        "$dir/other.conf"              => "allow virbr1\n",
    );
    my $hv = Test::HelperHV->new;

    is_deeply( [ Trog::HV::Libvirt::BridgeHelper::allowed_by_others( $hv, 'virbr1', 'runner' ) ], [qw{trog-runner-a.conf trog-runner-b.conf}], 'each other runner account whose file allows the bridge, sorted, and not the account itself, a longer name, or a file of something else' );
    is_deeply( [ Trog::HV::Libvirt::BridgeHelper::allowed_by_others( $hv, 'br0',    'runner' ) ], [],                                          'and none for a bridge that no other account may join' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
