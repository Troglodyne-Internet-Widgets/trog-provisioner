#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-diskqueue.t - the disks that the rule of diskqueue applies to

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

# A recipe per call: validated() is memoised on the object and answers the first
# set of arguments it was given.
sub fresh {
    return Provisioner::Cookbook->load( 'diskqueue', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

subtest 'the disks are the ones that the hypervisor names, unless the domain says' => sub {
    my %linode = fresh()->validate( domain => 'first.test', disk_devices => ['sd*'] );
    is_deeply( $linode{devices}, ['sd*'], 'a guest of a hypervisor that names its disks sdN gets sd*' );

    my %libvirt = fresh()->validate( domain => 'first.test', disk_devices => ['vd*'] );
    is_deeply( $libvirt{devices}, ['vd*'], 'and one that names them vdN gets vd*' );

    my %own = fresh()->validate( domain => 'first.test', disk_devices => ['sd*'], devices => ['nvme*'] );
    is_deeply( $own{devices}, ['nvme*'], 'and a domain that names its own devices keeps them' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
