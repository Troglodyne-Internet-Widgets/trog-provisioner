#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Utils.t - the helpers more than one module leans on

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();

use FindBin::libs;
use MIME::Base64();
use Crypt::KeyDerivation();

use_ok('Provisioner::Utils');

subtest 'fleet_address: what a name for another machine turns out to be' => sub {
    my %pool = ( ipmap => { 'cache.test.test' => '192.0.2.9' }, domain => 'guest.test.test' );
    my $ask  = sub { [ Provisioner::Utils::fleet_address( $_[0], %pool ) ] };

    is_deeply( $ask->(undef), [ none => q{} ], 'nothing named is no machine at all' );
    is_deeply( $ask->(q{}),   [ none => q{} ], 'and neither is an empty name' );

    # The scheme decides, not the dots: both of these are dotted.
    is_deeply( $ask->('http://cache.test.test:8080'), [ url => 'http://cache.test.test:8080' ], 'a URL is used exactly as written' );
    is_deeply( $ask->('HTTPS://Cache.test.test/'),    [ url => 'HTTPS://Cache.test.test/' ],    'whatever case its scheme is in' );

    is_deeply( $ask->('guest.test.test'), [ self    => q{} ],              'the guest asking about itself is told so' );
    is_deeply( $ask->('cache.test.test'), [ address => '192.0.2.9' ],      'a name the pool assigns resolves to its address' );
    is_deeply( $ask->('elsewhere.test'),  [ unknown => 'elsewhere.test' ], 'and one it does not comes back as the name' );

    # Self is checked before the pool, so a guest that is also in the pool --
    # which every guest is -- is still recognised as itself.
    my %own = ( ipmap => { 'guest.test.test' => '192.0.2.5' }, domain => 'guest.test.test' );
    is_deeply( [ Provisioner::Utils::fleet_address( 'guest.test.test', %own ) ], [ self => q{} ], 'even when the pool knows its address' );
};

subtest 'dns_name' => sub {
    is( Provisioner::Utils::dns_name('Lab.Example.NET.'), 'lab.example.net', 'a name compares in lower case without its dot' );
};

subtest 'tld_of is the last label, and nothing when there is none' => sub {
    is( Provisioner::Utils::tld_of('guest.test.test'),  'test',    'a name under a reserved TLD' );
    is( Provisioner::Utils::tld_of('host.example.net'), 'net',     'and under a public one' );
    is( Provisioner::Utils::tld_of('a.b.c.d.example'),  'example', 'however many labels precede it' );

    # The boundaries: letsencrypt decides from this whether a public CA could
    # ever issue for the name, and acmeca constrains a signing key to it, so an
    # answer where there is none is worse than no answer.
    is( Provisioner::Utils::tld_of('localhost'), undef, 'a single label names no TLD' );
    is( Provisioner::Utils::tld_of('trailing.'), undef, 'nor does a trailing dot' );
    is( Provisioner::Utils::tld_of(q{}),         undef, 'nor an empty string' );
    is( Provisioner::Utils::tld_of(undef),       undef, 'and undef is not a warning' );
};

subtest 'reserved_tld is the TLD only where RFC 2606 or RFC 6761 reserves it' => sub {
    is( Provisioner::Utils::reserved_tld($_), ( $_ =~ s/\A.*[.]//r ), "$_ is under a reserved TLD" ) for qw{a.test a.example a.invalid a.localhost};
    is_deeply( [ Provisioner::Utils::reserved_tld('host.example.net') ], [], 'a public name is not' );
    is_deeply( [ Provisioner::Utils::reserved_tld('test.example.net') ], [], 'nor is one that only starts with a reserved label' );
    is_deeply( [ Provisioner::Utils::reserved_tld('localhost') ],        [], 'nor a single label, which names no TLD' );
    is_deeply( [ Provisioner::Utils::reserved_tld(undef) ],              [], 'and undef is not a warning' );
};

subtest 'host_of reads the host out of the forms a repo_url takes' => sub {
    is( Provisioner::Utils::host_of('https://github.com/o/r.git'),      'github.com', 'an https clone URL' );
    is( Provisioner::Utils::host_of('https://gitea.test:3000/api/v1/'), 'gitea.test', 'a port is not part of the host' );
    is( Provisioner::Utils::host_of('HTTPS://GitHub.COM/o/r'),          'github.com', 'and the case it was written in is not either' );

    # URI reads no host out of an scp-style address, and somebody will certainly
    # configure one: it is what gogs hands out.
    is( Provisioner::Utils::host_of('git@github.com:o/r.git'),       'github.com', 'an scp-style git address, which is not a URL' );
    is( Provisioner::Utils::host_of('ssh://git@gitea.test/o/r.git'), 'gitea.test', 'and an ssh one, which is' );

    is( Provisioner::Utils::host_of('not a url'), undef, 'something that names no host' );
    is( Provisioner::Utils::host_of(q{}),         undef, 'and nothing at all' );
    is( Provisioner::Utils::host_of(undef),       undef, 'without warning about it' );
};

my $CERT = "-----BEGIN CERTIFICATE-----\nZm9v\n-----END CERTIFICATE-----\n";

subtest 'write_pem puts a PEM on disk byte for byte' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = "$dir/thing.crt";

    Provisioner::Utils::write_pem( $path, $CERT, 0644 );

    is( File::Slurper::read_binary($path), $CERT, 'the PEM, unchanged' );
};

subtest 'and with the mode it was asked for, which is the whole point for a key' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    Provisioner::Utils::write_pem( "$dir/key.pem",  "key\n",  0600 );
    Provisioner::Utils::write_pem( "$dir/cert.pem", "cert\n", 0644 );

    ## no critic (ProhibitLeadingZeros) -- file modes, which are octal
    is( sprintf( '%04o', ( stat "$dir/key.pem" )[2] & 07777 ),  '0600', 'a key is readable by its owner alone' );
    is( sprintf( '%04o', ( stat "$dir/cert.pem" )[2] & 07777 ), '0644', 'and a certificate, being public, by anybody' );
    ## use critic
};

subtest 'writing over one that is already there replaces both' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = "$dir/rolled.pem";

    Provisioner::Utils::write_pem( $path, "old\n", 0644 );
    Provisioner::Utils::write_pem( $path, "new\n", 0600 );

    ## no critic (ProhibitLeadingZeros) -- file modes, which are octal
    is( File::Slurper::read_binary($path),            "new\n", 'the content is the new one' );
    is( sprintf( '%04o', ( stat $path )[2] & 07777 ), '0600',  'and the mode is not the old one' );
    ## use critic
};

subtest 'somewhere it cannot write is fatal, not silent' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    # A key that was not written is a service that will not start.  Whoever is
    # reading the build output should be told, rather than finding out later.
    ok( exception { Provisioner::Utils::write_pem( "$dir/no/such/dir/key.pem", "key\n", 0600 ) }, 'a directory that does not exist' );
};

subtest 'dovecot_password_hash makes the Argon2id hash that dovecot reads' => sub {
    my $hash = Provisioner::Utils::dovecot_password_hash('s3cret');
    my $part = qr/([^\$]+)/;
    my ( $params, $salt, $digest ) = $hash =~ m/\A\{ARGON2ID\}\$argon2id\$v=19\$$part\$$part\$$part\z/;
    ok( defined $digest, 'the ARGON2ID scheme in front of the PHC string' ) or diag $hash;
    is( $params, 'm=65536,t=3,p=1', 'with the costs that doveadm pw uses' );

    # Decoded independently of the encoder: the digest is the Argon2id of the
    # password with the salt that the string carries.
    my ( $raw_salt, $raw_digest ) = map { MIME::Base64::decode_base64( $_ . '=' x ( -length($_) % 4 ) ) } $salt, $digest;
    is( length $raw_salt, 16,                                                                                     'a salt of 16 bytes' );
    is( $raw_digest,      Crypt::KeyDerivation::argon2_pbkdf( 'argon2id', 's3cret', $raw_salt, 3, 65536, 1, 32 ), 'whose digest is of that password' );
    isnt( Crypt::KeyDerivation::argon2_pbkdf( 'argon2id', 'wrong', $raw_salt, 3, 65536, 1, 32 ), $raw_digest, 'and of no other' );

    unlike( "$salt$digest", qr/=/, 'the salt and the digest in base64 with no padding, as the format wants' );
    isnt( Provisioner::Utils::dovecot_password_hash('s3cret'), $hash, 'and a new salt each time' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
