#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 nothing to see here

=cut

use FindBin::libs;
## no critic (ProhibitUnusedImports)
use Test::Pod::Coverage;
use Pod::Coverage::TrustPod;

unless ( $ENV{AUTHOR_TESTING} ) {
    print qq{1..0 # SKIP these tests are for testing by the author\n};
    exit;
}

all_pod_coverage_ok( { coverage_class => 'Pod::Coverage::TrustPod' } );
