#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/ipmap2zones.t - bin/ipmap2zones: zone files from the addresses the pool assigned

=cut

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Test::More;
use Test::Fatal   qw{exception};
use Capture::Tiny qw{capture_stdout};
use File::Temp();
use File::Slurper();
use File::Slurper::Temp();

use Provisioner::IPPool();

require_ok("$FindBin::Bin/../bin/ipmap2zones") or BAIL_OUT('bin/ipmap2zones does not load');

my $conf = $ENV{TROG_PROVISIONER_CONFIG};

# An ipmap.cfg with no [ips] section, as every installation has once its
# addresses moved into ips.db.
File::Slurper::Temp::write_text( "$conf/ipmap.cfg", "[global]\nadmin_email=hostmaster\@test.test\n" );

subtest 'with nothing assigned it says where it looked' => sub {
    my $out = File::Temp::tempdir( CLEANUP => 1 );
    my $err = exception {
        capture_stdout { Trog::Provisioner::IPMap2Zones::main( '--output-dir', $out ) }
    };
    like( $err, qr/ips[.]db/, 'it names the address database' );
};

subtest 'a zone for each domain the pool assigned' => sub {
    Provisioner::IPPool::record( '10.9.9.10', 'zoned.test.test' );

    my $out = File::Temp::tempdir( CLEANUP => 1 );
    my ($said) = capture_stdout { Trog::Provisioner::IPMap2Zones::main( '--output-dir', $out ) };
    like( $said, qr/zoned[.]test[.]test[.]zone/, 'it says which file it wrote' );

    my $zone = File::Slurper::read_text("$out/zoned.test.test.zone");
    like( $zone, qr/10[.]9[.]9[.]10/, 'and the zone holds the assigned address' );

    my $err = exception {
        capture_stdout { Trog::Provisioner::IPMap2Zones::main( '--output-dir', $out, 'nothere.test.test' ) }
    };
    like( $err, qr/nothere[.]test[.]test/, 'a domain with no address is named' );
};

done_testing();
