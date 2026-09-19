#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => q{all};

use re q{/aasx};

=head1 NAME

t/remotetests-gogs.t - the C<gogs> recipe generates, with its guest tests
(AUTHOR_TESTING only)

=cut

use FindBin::libs;
use Trog::Test::RemoteTests();

Trog::Test::RemoteTests::run(q{gogs});
