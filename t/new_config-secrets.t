#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/new_config-secrets.t - what bin/new_config tells bin/provision to put on a guest, and what it never writes down

=cut

# Every filetest here is on a file this test just made, in a temporary directory
# nothing else can see, so the TOCTOU policies have nothing to catch.
## no critic (ValuesAndExpressions::ProhibitFiletest_f, ValuesAndExpressions::ProhibitFiletest_e)

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Test::More;
use File::Temp();
use File::Slurper();
use YAML::XS();
use Trog::Secrets();

# Deliberately not t/new_config.t: that one runs under Test::MockFile in strict
# mode, and a secret store is a real file being really written to.
require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

sub store {
    my $dir  = File::Temp::tempdir( CLEANUP => 1 );
    my $kdbx = "$dir/secrets.kdbx";

    # Something already in it, so this is a store being added to rather than made.
    Trog::Secrets->write( $kdbx, 'throwaway', 'secret:seed/entry/password' => 'written by an operator' );
    return ( $dir, $kdbx );
}

sub signing_key_wanted {
    return (
        '/opt/domains/matrix.vm.test/homeserver.signing.key' => {
            ref      => 'secret:matrix/vm.test-signing-key/password',
            generate => sub { 'ed25519 a_test c2VjcmV0' },
            owner    => 'matrix-synapse:matrix-synapse',
            mode     => '0600',
        },
    );
}

subtest 'the manifest says where a secret goes, never what it is' => sub {
    my ( $dir, $kdbx ) = store();

    my %wanted = signing_key_wanted();
    my $held   = Trog::Provisioner::Config::Generator::write_guest_secrets( $dir, 'vm.test', \%wanted, $kdbx, 'throwaway' );

    is( $held->{'secret:matrix/vm.test-signing-key/password'}, 'ed25519 a_test c2VjcmV0', 'the secret was made and kept in the store' );

    my $manifest = "$dir/guest-secrets.yaml";
    ok( -f $manifest, 'a manifest was written beside the domain' );

    my $text = File::Slurper::read_binary($manifest);
    unlike( $text, qr/ed25519|c2VjcmV0/, 'and the secret itself is nowhere in it' );
    like( $text, qr{secret:matrix/vm\.test-signing-key/password}, 'only the reference that will fetch it' );

    my $read = YAML::XS::Load($text);
    is( $read->{'/opt/domains/matrix.vm.test/homeserver.signing.key'}{owner}, 'matrix-synapse:matrix-synapse', 'with the owner the file has to end up with' );
    is( $read->{'/opt/domains/matrix.vm.test/homeserver.signing.key'}{mode},  '0600',                          'and the mode' );

    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    is( ( stat $manifest )[2] & 07777, 0600, 'and the manifest is ours alone' );
};

subtest 'the same domain provisioned twice gets the same secret' => sub {
    my ( $dir, $kdbx ) = store();

    my $calls  = 0;
    my %wanted = (
        '/opt/domains/matrix.vm.test/homeserver.signing.key' => {
            ref      => 'secret:matrix/vm.test-signing-key/password',
            generate => sub { $calls++; return "ed25519 a_test made-$calls" },
            owner    => 'matrix-synapse:matrix-synapse',
            mode     => '0600',
        },
    );

    my $first  = Trog::Provisioner::Config::Generator::write_guest_secrets( $dir, 'vm.test', \%wanted, $kdbx, 'throwaway' );
    my $second = Trog::Provisioner::Config::Generator::write_guest_secrets( $dir, 'vm.test', \%wanted, $kdbx, 'throwaway' );

    is_deeply( $second, $first, 'the second run is answered with what the first one made' );
    is( $calls, 1, 'and nothing was generated twice' );
};

subtest 'a run that wants nothing placed leaves no manifest behind' => sub {
    my ( $dir, $kdbx ) = store();

    my %wanted = signing_key_wanted();
    Trog::Provisioner::Config::Generator::write_guest_secrets( $dir, 'vm.test', \%wanted, $kdbx, 'throwaway' );
    ok( -f "$dir/guest-secrets.yaml", 'there is one to start with' );

    # Otherwise bin/provision would go on placing a file no recipe asks for any
    # more, out of a manifest nothing rewrote.
    Trog::Provisioner::Config::Generator::write_guest_secrets( $dir, 'vm.test', {}, $kdbx, 'throwaway' );
    ok( !-e "$dir/guest-secrets.yaml", 'and asking for nothing takes it away' );
};

subtest 'the manifest is not something the guest is handed' => sub {

    # The payload is an explicit list -- the Makefile, what template_files
    # generated, openssl.conf, the scripts and t/ -- and the manifest is in none
    # of them.  It names references rather than secrets, but the guest has no
    # use for it either way, and a file that rides along is a file that ends up
    # in the tarball every backup keeps.
    my $packer = File::Slurper::read_text("$FindBin::Bin/../bin/new_config");
    my ($members) = $packer =~ m/my \@members = \((.*?)\);/s;

    ok( defined $members, 'found what goes into data.tar.gz' );
    unlike( $members // '', qr/guest-secrets/, 'and the manifest is not among it' );
};

done_testing();
