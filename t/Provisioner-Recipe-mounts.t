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
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my $recipe = Provisioner::Cookbook->load( 'mounts', distro => 'ubuntu' )->new(
    template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir    => '/nonexistent',
    distro        => 'ubuntu',
);

my %BASE = (
    domain      => 'mounts.test.test',
    install_dir => '/nonexistent',
    admin_user  => 'doge',
);

sub disk {
    my (%disk) = @_;
    my %opts = $recipe->validate( %BASE, disks => [ { mountpoint => '/bogus/mnt', type => 'ext4', options => 'noatime', %disk } ] );
    return $opts{disks}[0];
}

subtest 'a volume in a pool' => sub {
    my $default = disk( device => 'bogus-volume' );
    is( $default->{pool},      'default', 'is in the pool that libvirt calls default, by default' );
    is( $default->{partition}, 1,         'and mounts its first partition' );

    my $given = disk( device => 'bogus-volume', pool => 'bogus_pool', partition => 2 );
    is( $given->{pool},      'bogus_pool', 'the pool given is kept' );
    is( $given->{partition}, 2,            'and so is the partition' );

    like( exception { disk( device => 'bogus-volume', partition => 'two' ) }, qr{/disks/0/partition}, 'a partition that is not a number is refused' );
    like( exception { disk( device => 'bogus-volume', partition => 0 ) },     qr{/disks/0/partition}, 'and so is partition 0' );
};

# mount(8) calls it "defaults".  "default" is not a mount option.
subtest 'a directory on the hypervisor' => sub {
    my $shared = disk( device => tempdir( CLEANUP => 1 ) );
    is( $shared->{pool},      'dir',             'is shared as a directory' );
    is( $shared->{type},      'virtiofs',        'over virtiofs' );
    is( $shared->{partition}, 'NONE',            'with no partition' );
    is( $shared->{options},   'defaults,nofail', 'and options mount accepts' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
