#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-mounts.t - what a disk takes, and what it gets by default

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};

use FindBin::libs;

use Trog::Local();
use Provisioner::Cookbook();

my $recipe = Provisioner::Cookbook->load( 'mounts', distro => 'ubuntu' )->new(
    template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir    => '/nonexistent',
    distro        => 'ubuntu',
    hv            => Trog::Local->new(),
);

my %BASE = (
    domain      => 'mounts.test.test',
    install_dir => '/nonexistent',
    admin_user  => 'someadmin',
);

# The hypervisor, which has the directories and the block devices named here,
# and nothing else.  Each question it was asked goes into @ASKED.
my %ON_HV = (
    '/bogus/share'   => 'dir',
    '/bogus/dev/sdz' => 'block',
);
my @ASKED;
my $machine = Test::MockModule->new('Trog::Machine');
$machine->redefine( is_dir          => sub ( $, $path ) { push @ASKED, $path; ( $ON_HV{$path} // q{} ) eq 'dir'   ? 1 : 0 } );
$machine->redefine( is_block_device => sub ( $, $path ) { push @ASKED, $path; ( $ON_HV{$path} // q{} ) eq 'block' ? 1 : 0 } );

sub disk {
    my (%disk) = @_;
    my %opts = $recipe->validate( %BASE, disks => [ { mountpoint => '/bogus/mnt', type => 'ext4', options => 'noatime', %disk } ] );
    return $opts{disks}[0];
}

subtest 'a volume in a pool' => sub {
    @ASKED = ();
    my $default = disk( device => 'bogus-volume' );
    is( $default->{pool},      'default', 'is in the pool that libvirt calls default, by default' );
    is( $default->{partition}, 1,         'and mounts its first partition' );
    is_deeply( \@ASKED, [], 'and the hypervisor is not asked about a path relative to a pool' );

    my $given = disk( device => 'bogus-volume', pool => 'bogus_pool', partition => 2 );
    is( $given->{pool},      'bogus_pool', 'the pool given is kept' );
    is( $given->{partition}, 2,            'and so is the partition' );

    like( exception { disk( device => 'bogus-volume', partition => 'two' ) }, qr{/disks/0/partition}, 'a partition that is not a number is refused' );
    like( exception { disk( device => 'bogus-volume', partition => 0 ) },     qr{/disks/0/partition}, 'and so is partition 0' );
};

# mount(8) calls it "defaults".  "default" is not a mount option.
subtest 'a directory on the hypervisor' => sub {
    @ASKED = ();
    my $shared = disk( device => '/bogus/share' );
    is( $shared->{pool},      'dir',             'is shared as a directory, because the hypervisor has one there' );
    is( $shared->{type},      'virtiofs',        'over virtiofs' );
    is( $shared->{partition}, 'NONE',            'with no partition' );
    is( $shared->{options},   'defaults,nofail', 'and options mount accepts' );
    ok( ( grep { $_ eq '/bogus/share' } @ASKED ), 'the hypervisor was asked, not this machine' ) or diag explain \@ASKED;

    my $file = disk( device => '/bogus/disk.qcow2' );
    is( $file->{pool}, 'default', 'a path that the hypervisor has no directory or device at is not shared' );
    is( $file->{type}, 'ext4',    'and keeps its type' );
};

subtest 'a block device on the hypervisor' => sub {
    my $raw = disk( device => '/bogus/dev/sdz' );
    is( $raw->{pool},      'raw',  'is attached raw, because the hypervisor has a block device there' );
    is( $raw->{partition}, 1,      'and mounts its first partition' );
    is( $raw->{type},      'ext4', 'with the type given' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
