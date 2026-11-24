#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/ippool.t - bin/ippool: which database an operation goes to, and what it prints

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use Capture::Tiny    qw{capture};
use Cpanel::JSON::XS();
use File::Temp();

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Trog::SQLite();

require_ok("$FindBin::Bin/../bin/ippool") or die "could not require SUT: $@";

# What main printed, decoded, and what it returned.
sub ippool (@args) {
    my ( $out, undef, $code ) = capture { Provisioner::Bin::ippool::main(@args) };
    return ( Cpanel::JSON::XS->new->allow_nonref->decode($out), $code );
}

subtest '--hypervisor: the operation goes to the database of that hypervisor' => sub {
    my @asked;
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( on_hypervisor => sub ( $name, $op, $args ) { push @asked, [ $name, $op, $args ]; return { '192.0.2.10' => 'a.test.test' } } );

    my ( $said, $code ) = ippool( '--hypervisor=hv1', 'taken', '{"x":1}' );
    is_deeply( [ $said, $code ], [ { result => { '192.0.2.10' => 'a.test.test' } }, 0 ], 'it prints the result' );
    is_deeply( \@asked,          [ [ 'hv1', 'taken', { x => 1 } ] ],                     'of the operation on that hypervisor, with the arguments' );
};

subtest '--hypervisor migrate --from: the rows of the old database' => sub {
    my @asked;
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( migrate => sub ( $name, $from, %opts ) { push @asked, [ $name, $from, \%opts ]; return { added => 1 } } );

    my ($said) = ippool(qw{--hypervisor=hv1 migrate --from=/bogus/ips.db --bin=vpnclients --dryrun});
    is_deeply( $said,   { result => { added => 1 } },                                            'it prints what was migrated' );
    is_deeply( \@asked, [ [ 'hv1', '/bogus/ips.db', { bins => ['vpnclients'], dryrun => 1 } ] ], 'from the old database, with the bins and the dry run' );
};

subtest '--db: here, and a refusal is an answer too' => sub {
    Trog::SQLite::forget();
    my $path = File::Temp::tempdir( CLEANUP => 1 ) . '/ips.db';
    my ( $said, $code ) = ippool( "--db=$path", 'taken', '{}' );
    is( $code, 1, 'a database that is not there fails' );
    like( $said->{error}, qr/no[ ]address[ ]database/, 'and says so in JSON' );

    ( $said, $code ) = ippool( "--db=$path", qw{--create taken {}} );
    is_deeply( [ $said, $code ], [ { result => {} }, 0 ], 'unless it may make it' );
};

subtest 'it needs an operation, and one place to run it' => sub {
    my $usage = Test::MockModule->new( 'Provisioner::Bin::ippool', no_auto => 1 );
    $usage->redefine( pod2usage => sub (%opts) { die "usage: $opts{-message}\n" } );
    like( exception { Provisioner::Bin::ippool::main('--db=/bogus/ips.db') },                          qr/Name[ ]an[ ]operation/,                'no operation' );
    like( exception { Provisioner::Bin::ippool::main(qw{--db=/bogus/ips.db --hypervisor=hv1 taken}) }, qr/one[ ]of[ ]--db[ ]and[ ]--hypervisor/, 'and not two places' );
    like( exception { Provisioner::Bin::ippool::main('taken') },                                       qr/one[ ]of[ ]--db[ ]and[ ]--hypervisor/, 'nor none' );
};

done_testing();
