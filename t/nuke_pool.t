#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/nuke_pool.t - which options bin/nuke_pool takes before it touches a pool

=head1 DESCRIPTION

bin/nuke_pool removes a storage pool and every disk in it.  So nothing here lets
it reach a hypervisor: pod2usage, Trog::HV and Trog::Hypervisors are all
replaced with subs that die, and each case asks only which of them was reached.

=cut

use FindBin;
use FindBin::libs;
use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};

require_ok("$FindBin::Bin/../bin/nuke_pool") or BAIL_OUT('bin/nuke_pool does not load');

my $usage = Test::MockModule->new( 'Trog::Bin::NukePool', no_auto => 1 );
$usage->redefine( pod2usage => sub { my %opts = @_; die "usage exit $opts{-exitval}\n" } );

my $hv = Test::MockModule->new('Trog::HV');
$hv->redefine( new => sub { die "reached Trog::HV\n" } );

my $fleet = Test::MockModule->new('Trog::Hypervisors');
$fleet->redefine( load => sub { die "reached Trog::Hypervisors\n" } );

is( exception { Trog::Bin::NukePool::main('--help') }, "usage exit 0\n", '--help prints the usage and exits 0' );

is( exception { Trog::Bin::NukePool::main(qw{--domaindir /bogus}) }, "usage exit 2\n", '--domaindir is not an option, and nothing is reached' );

is( exception { Trog::Bin::NukePool::main(qw{--connect qemu:///bogus}) }, "usage exit 2\n", '--connect is gone, and an option that is not there is refused' );

done_testing();
