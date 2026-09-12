#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Trog-Utils.t - putting a PEM on disk with the mode it has to have

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();

use FindBin::libs;

use Trog::Utils();

my $CERT = "-----BEGIN CERTIFICATE-----\nZm9v\n-----END CERTIFICATE-----\n";

subtest 'it writes what it was given, byte for byte' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = "$dir/thing.crt";

    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    Trog::Utils::write_pem( $path, $CERT, 0644 );
    ## use critic

    is( File::Slurper::read_binary($path), $CERT, 'the PEM, unchanged' );
};

subtest 'and the mode it was asked for, which is the whole point for a key' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    ## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
    Trog::Utils::write_pem( "$dir/key.pem",  "key\n",  0600 );
    Trog::Utils::write_pem( "$dir/cert.pem", "cert\n", 0644 );

    is( sprintf( '%04o', ( stat "$dir/key.pem" )[2] & 07777 ),  '0600', 'a key is readable by its owner alone' );
    is( sprintf( '%04o', ( stat "$dir/cert.pem" )[2] & 07777 ), '0644', 'and a certificate, being public, by anybody' );
    ## use critic
};

subtest 'writing over one that is already there replaces both' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = "$dir/rolled.pem";

    ## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
    Trog::Utils::write_pem( $path, "old\n", 0644 );
    Trog::Utils::write_pem( $path, "new\n", 0600 );

    is( File::Slurper::read_binary($path),            "new\n", 'the content is the new one' );
    is( sprintf( '%04o', ( stat $path )[2] & 07777 ), '0600',  'and the mode is not the old one' );
    ## use critic
};

subtest 'somewhere it cannot write is fatal, not silent' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    # A key that was not written is a service that will not start.  Whoever is
    # reading the build output should be told, rather than finding out later.
    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    ok( exception { Trog::Utils::write_pem( "$dir/no/such/dir/key.pem", "key\n", 0600 ) }, 'a directory that does not exist' );
    ## use critic
};

Test::NoWarnings::had_no_warnings();

done_testing;
