#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-acmeca.t - the internal ACME CA: the intermediate it issues
from, what keeps that intermediate from signing anything else, and what of the
authority does and does not travel to the guest

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();
use IO::Socket::SSL::Utils();
use Net::SSLeay();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: the authority is made
# there on first use, and what these assert on should not depend on the machine.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();
use Provisioner::Recipe::acmeca();

my $DOMAIN = 'acmeca.test.test';

sub generated {
    my (%extra) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'acmeca', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    my %vars = (
        domain       => $DOMAIN,
        main_ip      => '192.168.1.9',
        full_aliases => ["www.$DOMAIN"],
        install_dir  => '/opt/domains',
        script_dir   => '/root/bin',
        resolvers    => [ '192.168.1.253', '8.8.8.8' ],
        %extra,
    );

    my @written = $recipe->generate_files( $dir, %vars );
    return ( $recipe, $dir, \@written, $recipe->render(%vars) );
}

# What one of a certificate's extensions says, as openssl prints it.
sub extension {
    my ( $cert, $name ) = @_;
    my ($ext) = grep { $_->{sn} eq $name } @{ IO::Socket::SSL::Utils::CERT_asHash($cert)->{ext} // [] };
    return $ext ? $ext->{data} : 'none';
}

subtest 'what the guest is given, and what is kept back' => sub {
    my ( undef, $dir, $written ) = generated();

    foreach my $file (qw{acmeca-root.crt acmeca-intermediate.crt acmeca-intermediate.key acmeca.ca.json acmeca.service}) {
        ok( ( grep { $_ eq $file } @$written ), "$file is written into the payload" );
    }

    # The authority private key is the one thing that must not travel: a guest
    # holding it could issue from the root itself, and the name constraint below
    # is on the intermediate rather than on the root.
    ok( !-e "$dir/fetchcache-ca.key", 'the authority private key does not go with it' );
    ok( !-e "$dir/acmeca-root.key",   'and it is not written out under another name' );
};

subtest 'the intermediate is issued by the authority the fetch cache signs with' => sub {
    my ( undef, $dir ) = generated();

    my $authority = Provisioner::Cookbook->load('fetchcache')->authority();
    is(
        File::Slurper::read_text("$dir/acmeca-root.crt"),
        File::Slurper::read_text( $authority->{cert} ),
        'the root handed over is that authority, not a second one'
    );

    my $root         = IO::Socket::SSL::Utils::PEM_file2cert( $authority->{cert} );
    my $intermediate = IO::Socket::SSL::Utils::PEM_file2cert("$dir/acmeca-intermediate.crt");
    is( Net::SSLeay::X509_verify( $intermediate, Net::SSLeay::X509_get_pubkey($root) ), 1, 'and the intermediate verifies against it' );

    is( extension( $intermediate, 'basicConstraints' ), 'CA:TRUE', 'the intermediate is a CA, so step-ca can issue from it' );
};

subtest 'the intermediate may not vouch for anything outside the TLD it was made for' => sub {

    # This is the whole of what keeps a key on a throwaway guest from being a
    # trusted signing key for the internet: the authority above it carries no
    # name constraints and is in the trust store of every guest that provisions
    # through the fetch cache.
    my ( undef, $dir ) = generated();
    my $intermediate = IO::Socket::SSL::Utils::PEM_file2cert("$dir/acmeca-intermediate.crt");
    like( extension( $intermediate, 'nameConstraints' ), qr/DNS:[.]test/, 'by default it is constrained to .test' );

    ( undef, $dir ) = generated( constrain_to => 'internal' );
    $intermediate = IO::Socket::SSL::Utils::PEM_file2cert("$dir/acmeca-intermediate.crt");
    my $constraints = extension( $intermediate, 'nameConstraints' );
    like( $constraints, qr/DNS:[.]internal/, 'and to whatever else it is told' );
    unlike( $constraints, qr/DNS:[.]test\b/, 'to that alone, rather than to both' );
};

subtest 'the private key belongs to the guest which holds it alone' => sub {
    my ( undef, $dir ) = generated();

    ## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
    my @stat = stat("$dir/acmeca-intermediate.key");
    ok( @stat, 'the intermediate key was written' ) or return;
    is( sprintf( '%04o', $stat[2] & 07777 ), '0600', 'nobody but its owner can read it' );

    my @cert = stat("$dir/acmeca-intermediate.crt");
    is( sprintf( '%04o', $cert[2] & 07777 ), '0644', 'and the certificate, being public, is readable' );
    ## use critic
};

subtest 'it answers on loopback and nowhere else' => sub {
    my ( undef, $dir ) = generated();

    like( File::Slurper::read_text("$dir/acmeca.ca.json"), qr/"address":\s*"127[.]0[.]0[.]1:9000"/, 'the default port, bound to loopback' );

    ( undef, $dir ) = generated( port => 9443 );
    like( File::Slurper::read_text("$dir/acmeca.ca.json"), qr/"address":\s*"127[.]0[.]0[.]1:9443"/, 'and a configured one, still on loopback' );
};

subtest 'it issues through the challenge the guest can actually answer' => sub {
    my ( undef, $dir ) = generated();
    my $config = File::Slurper::read_text("$dir/acmeca.ca.json");

    # dns-01 and no other: the guest serves its own zone, and nothing routes to
    # it from a public network for http-01 or tls-alpn-01 to use.
    like( $config, qr/"challenges":\s*\[\s*"dns-01"\s*\]/, 'dns-01, and only dns-01' );
    like( $config, qr/"type":\s*"ACME"/,                   'from an ACME provisioner' );
};

subtest 'the pinned version is the one the guest is told to fetch' => sub {
    my ( undef, undef, undef, $fragment ) = generated();

    # Read off the module rather than written out here: a test naming the
    # version too would be a second place to bump, and would pass while saying
    # nothing about what the fragment actually fetches.
    my $pinned = $Provisioner::Recipe::acmeca::STEP_CA_VERSION;
    like( $fragment, qr/\Qreleases\/download\/v$pinned\/step-ca_linux_${pinned}_\E/, "the download names the pinned $pinned" );

    ( undef, undef, undef, $fragment ) = generated( version => '9.9.9' );
    like( $fragment, qr/v9[.]9[.]9/, 'and a version an operator chose instead' );
};

subtest 'the CA can name itself under its own constraint' => sub {

    # step-ca issues its own listener certificate from this intermediate when it
    # starts, for the names in ca.json, and refuses to start at all when the
    # constraint forbids one of them.  Measured on a guest, where it crash-looped
    # on: DNS name "localhost" is not permitted by any constraint.  Nothing in
    # the recipe couples those two lists, so this is what keeps them agreeing.
    my ( undef, $dir ) = generated();

    my ($listed) = File::Slurper::read_text("$dir/acmeca.ca.json") =~ m/"dnsNames":\s*\[([^\]]*)\]/;
    my @names = $listed =~ m/"([^"]+)"/g;
    ok( @names, 'ca.json says what the CA answers to' ) or return;

    my @permitted = extension( IO::Socket::SSL::Utils::PEM_file2cert("$dir/acmeca-intermediate.crt"), 'nameConstraints' ) =~ m/DNS:(\S+)/g;
    foreach my $name (@names) {

        # A permitted entry starting with a dot is a suffix; anything else is
        # the whole name.
        my $allowed = grep { m/\A[.]/ ? ".$name" =~ m/\Q$_\E\z/ : $_ eq $name } @permitted;
        ok( $allowed, "the CA may issue itself $name, which it needs to start" ) or diag "permitted: @permitted";
    }
};

subtest 'it depends on the recipe that answers its challenges' => sub {
    my ($recipe) = generated();
    my %required = $recipe->required_recipes( domain => $DOMAIN );

    ok( exists $required{pdns}, 'pdns is required, since the challenge is a record it serves' );

    # Handing it nothing is the point: pdns requires an api_key, and one nobody
    # chose is worse than a build that stops and says so.
    is_deeply( [ $required{pdns}->() ], [], 'and it is handed nothing to configure it with' );
};

subtest 'a constraint that is not a name is refused' => sub {
    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'acmeca', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    ok( exception { $recipe->validate( domain => $DOMAIN, constrain_to => 'not a tld' ) }, 'rather than written into a certificate' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
