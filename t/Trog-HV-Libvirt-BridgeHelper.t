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

use FindBin::libs;

BEGIN { use_ok('Trog::HV::Libvirt::BridgeHelper') or BAIL_OUT('Trog::HV::Libvirt::BridgeHelper does not load') }

my $CONF = $Trog::HV::Libvirt::BridgeHelper::CONF;

{

    # A hypervisor that has the files of @HAVE.
    package Test::HelperHV;
    our @HAVE;
    sub new ($class) { return bless {}, $class }

    sub file_exists ( $, $path ) {
        return List::Util::any { $_ eq $path } @HAVE;
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

Test::NoWarnings::had_no_warnings();
done_testing();
