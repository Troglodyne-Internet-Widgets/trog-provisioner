#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Packager-Deb.t - a vendor archive, from what a recipe names to the
files that apt reads

=cut

use Test::More;
use Test::Fatal;
use Test::MockModule qw{strict};
use Test::NoWarnings qw{had_no_warnings};
use MIME::Base64     qw{decode_base64};
use File::Slurper::Temp();
use File::Temp();
use File::Which();
use IPC::Run3();

use FindBin::libs;

use_ok('Provisioner::Packager::Deb');

my $ARMORED = "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQINBGbogus\n-----END PGP PUBLIC KEY BLOCK-----\n";

# An old-format public key packet starts 0x99.
my $BINARY = pack( 'C*', 0x99, 0x01, 0x0d ) . 'bogus-binary-key';

# What the network answers, by URL.  A URL that is not here is a 404, and every
# request is counted.
my ( %answer, %asked );
my $mock = Test::MockModule->new('Provisioner::Packager::Deb');
$mock->redefine(
    fetch => sub {
        my ( $url, $method ) = @_;
        $asked{ ( $method // 'GET' ) . " $url" }++;
        return exists $answer{$url}
          ? { success => 1, status => 200, reason => 'OK',        content => $answer{$url} }
          : { success => 0, status => 404, reason => 'Not Found', content => q{} };
    }
);

sub source {
    my (%over) = @_;
    return {
        name       => 'vendor',
        uri        => 'https://apt.vendor.test/debian',
        suites     => ['stable'],
        components => ['main'],
        key        => 'https://apt.vendor.test/key.asc',
        %over,
    };
}

subtest 'merge: what a source must say' => sub {
    my @ok = Provisioner::Packager::Deb->merge( source() );
    is( scalar @ok, 1, 'a whole source passes' );

    like( exception { Provisioner::Packager::Deb->merge( source( name   => 'Vendor Archive' ) ) },        qr/Vendor[ ]Archive[ ]is[ ]not[ ]a[ ]valid[ ]apt[ ]source/, 'a name that is not a file name is refused, by name' );
    like( exception { Provisioner::Packager::Deb->merge( source( key    => undef ) ) },                   qr/not[ ]a[ ]valid/,                                        'a source with no key is refused' );
    like( exception { Provisioner::Packager::Deb->merge( source( uri    => 'ftp://apt.vendor.test' ) ) }, qr/uri/,                                                    'and one that apt cannot fetch over http' );
    like( exception { Provisioner::Packager::Deb->merge( source( suites => [] ) ) },                      qr/suites/,                                                 'and one with no suite' );
    like( exception { Provisioner::Packager::Deb->merge( source( pin    => { packages => 'x' } ) ) },     qr/priority/,                                               'and a pin with no priority' );
    like( exception { Provisioner::Packager::Deb->merge( source( signed => 1 ) ) },                       qr/signed/,                                                 'and a key it does not know' );
};

subtest 'merge: two recipes can name one archive' => sub {
    my @same = Provisioner::Packager::Deb->merge( source(), source() );
    is( scalar @same, 1, 'the same archive twice is one source' );

    like(
        exception { Provisioner::Packager::Deb->merge( source(), source( suites => ['testing'] ) ) },
        qr/Two[ ]recipes[ ]name[ ]the[ ]apt[ ]source[ ]vendor/,
        'and one name for two different archives is refused'
    );

    my ($pinned) = Provisioner::Packager::Deb->merge( source( pin => { priority => 600 } ) );
    is( $pinned->{pin}{packages}, q{*}, 'a pin with no packages pins every package' );
};

subtest 'files: an armored key, a source and a pin' => sub {
    %answer = (
        'https://apt.vendor.test/key.asc'                         => $ARMORED,
        'https://apt.vendor.test/debian/dists/stable/InRelease'   => q{},
        'https://apt.vendor.test/debian/dists/unstable/InRelease' => q{},
    );
    my @files = Provisioner::Packager::Deb->files(
        Provisioner::Packager::Deb->merge(
            source(
                uri           => 'https://apt.vendor.test/debian/',
                suites        => [qw{stable unstable}],
                components    => [qw{main contrib}],
                architectures => ['amd64'],
                pin           => { packages => 'vendor-*', priority => 600 },
            )
        )
    );
    my %file = map { $_->{path} => $_ } @files;

    is_deeply( [ sort keys %file ], [qw{/etc/apt/keyrings/vendor.asc /etc/apt/preferences.d/vendor.pref /etc/apt/sources.list.d/vendor.sources}], 'a key, a source and a pin' );
    is( $file{'/etc/apt/keyrings/vendor.asc'}{content}, $ARMORED, 'the armored key as it came, which apt reads from a .asc' );
    ok( !$file{'/etc/apt/keyrings/vendor.asc'}{encoding}, 'as text' );
    is( $file{'/etc/apt/sources.list.d/vendor.sources'}{content}, <<'SOURCES', 'the source in deb822, signed by that key' );
Types: deb
URIs: https://apt.vendor.test/debian/
Suites: stable unstable
Components: main contrib
Architectures: amd64
Signed-By: /etc/apt/keyrings/vendor.asc
SOURCES
    is( $file{'/etc/apt/preferences.d/vendor.pref'}{content},                   "Package: vendor-*\nPin: origin apt.vendor.test\nPin-Priority: 600\n", 'the pin names the host of the archive' );
    is( $asked{'HEAD https://apt.vendor.test/debian/dists/unstable/InRelease'}, 1,                                                                     'each suite was asked for, without the doubled slash' );
    is( scalar( grep { $_->{permissions} ne '0644' } @files ),                  0,                                                                     'every file is 0644' );
};

subtest 'files: a binary key' => sub {
    %answer = (
        'https://apt.binary.test/key.gpg'                => $BINARY,
        'https://apt.binary.test/dists/stable/InRelease' => q{},
    );
    my @files = Provisioner::Packager::Deb->files( source( name => 'binary', uri => 'https://apt.binary.test', key => 'https://apt.binary.test/key.gpg' ) );
    my ($key) = grep { $_->{path} =~ m{keyrings} } @files;

    is( $key->{path},                     '/etc/apt/keyrings/binary.gpg', 'a binary key goes in a .gpg' );
    is( $key->{encoding},                 'b64',                          'base64, because the user-data is text' );
    is( decode_base64( $key->{content} ), $BINARY,                        'and it decodes to the key' );
    ok( !grep( { $_->{path} =~ m{preferences} } @files ), 'no pin without one' );
};

subtest 'files: what stops the build' => sub {
    %answer = ( 'https://apt.portal.test/key' => "<html>Please log in</html>\n" );
    my $page = exception { Provisioner::Packager::Deb->files( source( name => 'portal', key => 'https://apt.portal.test/key' ) ) };
    $page //= q{};
    like( $page, qr/is[ ]not[ ]a[ ]PGP[ ]key/, 'a page in place of a key' );
    like( $page, qr{apt[.]portal[.]test/key},  'names where it came from' );

    %answer = ();
    my $gone = exception { Provisioner::Packager::Deb->files( source( name => 'gone', key => 'https://apt.gone.test/key' ) ) };
    $gone //= q{};
    like( $gone, qr/Could[ ]not[ ]fetch[ ]the[ ]signing[ ]key/, 'a key that is not there' );
    like( $gone, qr/apt[ ]source[ ]gone[ ]from[ ]\S+:[ ]404/,   'names the source and the answer' );

    %answer = ( 'https://apt.nosuite.test/key' => $ARMORED );
    my $suite = exception { Provisioner::Packager::Deb->files( source( name => 'nosuite', uri => 'https://apt.nosuite.test', key => 'https://apt.nosuite.test/key', suites => ['noble'] ) ) };
    $suite //= q{};
    like( $suite, qr/The[ ]apt[ ]source[ ]nosuite[ ]has[ ]no[ ]suite[ ]noble/, 'an archive with no index for the suite' );
    like( $suite, qr{/dists/noble/InRelease[ ]answered[ ]404},                 'names what it asked for' );
};

subtest 'files: a key is fetched once' => sub {
    %answer = (
        'https://apt.once.test/key'                    => $ARMORED,
        'https://apt.once.test/dists/stable/InRelease' => q{},
    );
    Provisioner::Packager::Deb->files( source( name => 'once', uri => 'https://apt.once.test', key => 'https://apt.once.test/key' ) ) for 1 .. 2;
    is( $asked{'GET https://apt.once.test/key'},                     1, 'for two domains that name it' );
    is( $asked{'HEAD https://apt.once.test/dists/stable/InRelease'}, 1, 'and so is each suite' );
};

# Keys that gpg makes here, and what gpg says their fingerprints are, so that
# key_fingerprints is held to gpg rather than to itself.
subtest 'files: a key that must have its fingerprint' => sub {
    my $gpg = File::Which::which('gpg');
    plan skip_all => 'no gpg here to make keys with' unless $gpg;
    my $home = File::Temp::tempdir( CLEANUP => 1 );
    my $run  = sub {
        my (@args) = @_;
        IPC::Run3::run3( [ $gpg, '--homedir', $home, '--batch', @args ], \undef, \my $out, \my $err );
        die "gpg @args: $err" if $?;
        return $out;
    };
    $run->( qw{--passphrase}, q{}, '--quick-gen-key', 'one <one@test.test>', qw{rsa2048 sign never} );
    $run->( qw{--passphrase}, q{}, '--quick-gen-key', 'two <two@test.test>', qw{ed25519 sign never} );
    my %fpr = map { ( $_ => ( $run->( qw{--with-colons --list-keys}, "$_\@test.test" ) =~ m/^fpr:+([[:xdigit:]]{40}):/m )[0] ) } qw{one two};
    $run->( '--passphrase', q{}, '--quick-add-key', $fpr{one}, qw{rsa2048 encr never} );

    my $armored = $run->( qw{--armor --export}, 'one@test.test' );
    my $binary  = $run->( qw{--export},         'one@test.test' );
    my $both    = $run->(qw{--armor --export});
    is_deeply( [ Provisioner::Packager::Deb::key_fingerprints($armored) ],      [ $fpr{one} ],              'the fingerprint of an armored key, with a subkey, is what gpg says, once' );
    is_deeply( [ Provisioner::Packager::Deb::key_fingerprints($binary) ],       [ $fpr{one} ],              'and of the same key in binary' );
    is_deeply( [ sort( Provisioner::Packager::Deb::key_fingerprints($both) ) ], [ sort @fpr{qw{one two}} ], 'and a file of two keys has two' );
    like( exception { Provisioner::Packager::Deb::key_fingerprints('not a key') }, qr/gpg[ ]reads[ ]no[ ]OpenPGP[ ]key/, 'what is not a key is refused' );
    {
        no warnings 'once';
        local @Provisioner::Packager::Deb::GPG = ('/bogus/gpg');
        like( exception { Provisioner::Packager::Deb::key_fingerprints($armored) }, qr/needs[ ]gpg/,            'and without gpg, nothing is trusted' );
        like( Provisioner::Packager::Deb->gpg_error,                                qr/gpg[ ]does[ ]not[ ]run/, 'which gpg_error says' );

        # A gpg from before --show-keys, which says only its version.
        my $old = "$home/old-gpg";
        File::Slurper::Temp::write_text( $old, qq{#!/bin/sh\necho 'gpg (GnuPG) 2.2.4'\n} );
        chmod 0755, $old or die "chmod: $!";
        local @Provisioner::Packager::Deb::GPG = ($old);
        like( Provisioner::Packager::Deb->gpg_error, qr/GnuPG[ ]2[.]2[.]4.*2[.]2[.]8[ ]or[ ]later/, 'and so for a gpg too old to show a key without importing it' );
    }
    is( Provisioner::Packager::Deb->gpg_error, undef, 'the gpg here reads keys' );

    my %suite = ( 'https://apt.fpr.test/dists/stable/InRelease' => q{} );
    %answer = ( %suite, 'https://apt.fpr.test/one.asc' => $armored, 'https://apt.fpr.test/both.asc' => $both );
    my %fpr_source = ( name => 'fpr', uri => 'https://apt.fpr.test', key => 'https://apt.fpr.test/one.asc' );
    my ($keyring)  = Provisioner::Packager::Deb->files( source( %fpr_source, fingerprint => lc $fpr{one} ) );
    is( $keyring->{content}, $armored, 'a key with the fingerprint of its source is written, whatever its case' );
    like( exception { Provisioner::Packager::Deb->files( source( %fpr_source, fingerprint => $fpr{two} ) ) }, qr/is[ ]$fpr{one},[ ]not[ ]$fpr{two}/, 'one with another stops the build' );
    like( exception { Provisioner::Packager::Deb->files( source( %fpr_source, key => 'https://apt.fpr.test/both.asc', fingerprint => $fpr{one} ) ) }, qr/[ ]and[ ]/, 'and so does a file that holds a second key beside it' );

    is( scalar Provisioner::Packager::Deb->merge( source( fingerprint => $fpr{one} ) ), 1, 'merge takes a source with a fingerprint' );
    like( exception { Provisioner::Packager::Deb->merge( source( fingerprint => 'ABCD' ) ) }, qr/fingerprint/, 'and refuses one that is not 40 hex digits' );
};

subtest 'forbid: a pin that keeps packages out, for one domain' => sub {
    is_deeply( [ Provisioner::Packager::Deb->forbid('one.test') ], [], 'no packages, no file' );

    my ($pin) = Provisioner::Packager::Deb->forbid( 'one.test', qw{apache2 ntp} );
    is( $pin->{path},    '/etc/apt/preferences.d/one.test-conflicts.pref',             'named for the domain, so a second domain on the guest keeps it' );
    is( $pin->{content}, "Package: apache2 ntp\nPin: release a=*\nPin-Priority: -1\n", 'below zero, from every archive' );
};

had_no_warnings();
done_testing();
