#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

# The script is loaded when the test runs rather than when it compiles, so perl
# sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/synczones.t - scripts/synczones: what zonediff decides to create, update and
delete, and which renderings of a record it counts as the same one

=cut

use Test::More;
use Net::DNS::RR();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/synczones";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# A record as the zonefile has it.  Net::DNS::RR->plain is what zonediff
# compares against, and for TXT that carries the quotes.
sub rr {
    my ($spec) = @_;

    return Net::DNS::RR->new($spec);
}

# A record as the provider hands it back.
sub remote {
    my (%row) = @_;

    return \%row;
}

# zonediff consumes both of its arguments, so every case builds its own.
sub diff {
    my ( $from_file, $actual ) = @_;

    return { ZoneSyncer::zonediff( $from_file, $actual ) };
}

subtest 'a record the provider already has is left alone' => sub {
    my $crud = diff(
        [ rr('foo.test. 300 IN TXT "hello"') ],
        [ remote( name => 'foo.test', ttl => 300, type => 'TXT', content => '"hello"', id => 'id-1' ) ],
    );

    is( scalar @{ $crud->{create} }, 0, 'nothing to create' );
    is( scalar @{ $crud->{update} }, 0, 'nothing to update' );
    is( scalar @{ $crud->{delete} }, 0, 'nothing to delete' );
};

subtest 'the same record unquoted by the provider is still the same record' => sub {
    my $crud = diff(
        [ rr('foo.test. 300 IN TXT "hello"') ],
        [ remote( name => 'foo.test', ttl => 300, type => 'TXT', content => 'hello', id => 'id-1' ) ],
    );

    is( scalar @{ $crud->{create} }, 0, 'nothing to create' )
      or diag 'the quoted and unquoted renderings were read as two records';
    is( scalar @{ $crud->{delete} }, 0, 'nothing to delete' );
};

# The provider having nothing at all is the ordinary first sync of a zone, and
# the scan used to shift one more time than it had records to look at.
subtest 'a record the provider does not have at all is created' => sub {
    my $crud = diff( [ rr('bar.test. 600 IN A 10.0.0.1') ], [] );

    is( scalar @{ $crud->{create} }, 1,          'one record to create' );
    is( $crud->{create}[0]{name},    'bar.test', 'named for the zonefile owner' );
    is( $crud->{create}[0]{content}, '10.0.0.1', 'carrying its rdata' );
    is( scalar @{ $crud->{delete} }, 0,          'and nothing to delete' );
};

subtest 'a record whose content differs replaces the one that is there' => sub {
    my $crud = diff(
        [ rr('bar.test. 600 IN A 10.0.0.1') ],
        [ remote( name => 'bar.test', ttl => 600, type => 'A', content => '10.0.0.9', id => 'id-9' ) ],
    );

    is( scalar @{ $crud->{create} }, 1,      'the wanted record is created' );
    is( scalar @{ $crud->{delete} }, 1,      'and the one that was there is deleted' );
    is( $crud->{delete}[0]{id},      'id-9', 'the deletion names the provider identifier' );
};

subtest 'SOA and NS are updated rather than replaced' => sub {
    my $crud = diff(
        [ rr('baz.test. 900 IN SOA ns.test. root.test. 1 2 3 4 5') ],
        [ remote( name => 'baz.test', ttl => 900, type => 'SOA', content => 'ns.test. root.test. 9 2 3 4 5', id => 'id-soa' ) ],
    );

    is( scalar @{ $crud->{update} }, 1, 'one record to update' );
    is( scalar @{ $crud->{create} }, 0, 'and none to create' );
    is( scalar @{ $crud->{delete} }, 0, 'and none to delete, there being only one SOA' );
};

# main() puts this on the lexicon command line as --identifier for any action
# that is not a create, so an update without one cannot be issued at all.
subtest 'an update names the record it is updating' => sub {
    my $crud = diff(
        [ rr('baz.test. 900 IN SOA ns.test. root.test. 1 2 3 4 5') ],
        [ remote( name => 'baz.test', ttl => 900, type => 'SOA', content => 'ns.test. root.test. 9 2 3 4 5', id => 'id-soa' ) ],
    );

    is( $crud->{update}[0]{id}, 'id-soa', 'the update carries the provider identifier' );
};

done_testing();
