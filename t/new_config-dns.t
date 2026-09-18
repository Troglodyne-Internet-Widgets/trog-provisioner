#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/new_config-dns.t - what the depsolver does with a substitutable dependency,
one named as an interface rather than as a recipe

=cut

# Asserting a file was generated is what this file does, and -f is how you ask.
## no critic (ValuesAndExpressions::ProhibitFiletest_f)

use FindBin;
use FindBin::libs;

# Never the installation's real configuration: what this asserts should not
# depend on which machine it runs on.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempdir tempfile};
use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();

use Provisioner::Cookbook();
use Trog::Credentials();
use Trog::Secrets();

# The administrator's keys are read out of the configuration directory now,
# rather than named as an identity for cloud-init to fetch at first boot.
File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAdogeskey doge\n" );

require Trog::HV;
require Trog::HV::Libvirt;

# The two facts the generator asks a hypervisor for, answered here so this runs
# on a machine that is not one.
my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
$hv_mock->redefine( virbr_ip  => sub { '192.168.122.1' } );
$hv_mock->redefine( sshd_port => sub { 22 } );

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

# Reserved, so the guest holds its own zone; public, so somebody else does.
my $LOCAL  = 'local.test';
my $REMOTE = 'remote.troglodyne.net';

sub generate {
    my ( $domain, %recipes_for ) = @_;

    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/domains";
    mkdir "$tmpdir/data";
    mkdir "$tmpdir/data/$domain";

    my $pool = join( ' ', map { "192.168.1.$_" } 100 .. 199 );

    # One resolver on purpose.  Config::Simple hands back a bare string for a
    # single-valued key, and bin/new_config dereferenced that raw when it wrote
    # provision.conf -- so generating from this is what catches it coming back.
    my $ipmap = <<"IPMAP";
[global]
ip=192.168.1.50
basedir=$tmpdir/domains
transfer_user=doge
admin_user=doge
admin_email=bogus\@test.test
admin_gecos=Test Test
gateway=192.168.1.254
resolvers=192.168.1.254
bridge_devname=ens4
dhcp_devname=ens3
[ip_pool]
addresses=$pool
[nameservers]
ns1=ns1.test.test
ns2=ns2.test.test
IPMAP

    my %recipes = (
        _base   => { _global => { data_source => "$tmpdir/data" } },
        $domain => \%recipes_for,
    );

    my ( $ih, $ipmap_file ) = tempfile();
    print {$ih} $ipmap;
    close($ih) or die "Could not close $ipmap_file: $!";

    # Inside the configuration directory, because that is where every real run
    # keeps it: bin/provision points TROG_PROVISIONER_CONFIG and --recipes at
    # the same place, so a recipe asking about a sibling sees the run it is part
    # of.  Written apart, the two disagree and nothing is configured at all.
    my $recipe_file = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";
    File::Slurper::Temp::write_text( $recipe_file, YAML::XS::Dump( \%recipes ) );

    Provisioner::Cookbook->forget();

    my $err = exception {
        Trog::Provisioner::Config::Generator::main( '--ipmap', $ipmap_file, '--recipes', $recipe_file, '--skip_ssh', $domain );
    };

    my $makefile = "$tmpdir/domains/$domain/Makefile";

    # The generated files as well as the makefile: a recipe that installs
    # nothing has no target to assert on, and what it contributed is visible
    # only in what somebody else rendered out of it.
    return ( $err, ( -f $makefile ? File::Slurper::read_text($makefile) : undef ), "$tmpdir/domains/$domain" );
}

# Which recipes the generated makefile actually builds, as targets under the
# state directory.  Asking the makefile rather than the generator means this
# says what a guest would run, not what a data structure held.
sub builds {
    my ( $makefile, $recipe ) = @_;
    return 0 unless defined $makefile;

    # The state target, anchored, rather than the word anywhere in the file:
    # a recipe's name turns up in paths, comments and other recipes' output, so
    # a loose match would answer yes for a recipe that is not built at all.
    return $makefile =~ m{^/etc/provisioner/state/(?:global_|[^/]+/)\Q$recipe\E:}m ? 1 : 0;
}

subtest 'a credential written as a secret reference reaches the hook resolved' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/domains";
    mkdir "$tmpdir/data";
    mkdir "$tmpdir/data/$REMOTE";

    # A real store, not a stubbed read: what this is about is a password making
    # it from the database into a rendered file, so faking the database out
    # would skip the part that broke.
    my $kdbx = "$tmpdir/secrets.kdbx";
    Trog::Secrets->create( $kdbx, 'throwaway', 'secret:dns/registrar/password' => 'REAL-PASSWORD' );

    # Seeded rather than mocked: prompt() hands back a credential this run has
    # already been given, so the generator never reaches for a terminal.
    Trog::Credentials->remember( 'keepass', 'throwaway' );

    my $pool = join( ' ', map { "192.168.1.$_" } 100 .. 199 );
    my ( $ih, $ipmap_file ) = tempfile();
    print {$ih} <<"IPMAP";
[global]
ip=192.168.1.50
basedir=$tmpdir/domains
transfer_user=doge
admin_user=doge
admin_email=bogus\@test.test
admin_gecos=Test Test
gateway=192.168.1.254
resolvers=192.168.1.254
bridge_devname=ens4
dhcp_devname=ens3
[ip_pool]
addresses=$pool
[nameservers]
ns1=ns1.test.test
ns2=ns2.test.test
IPMAP
    close($ih) or die "Could not close $ipmap_file: $!";

    my $recipe_file = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";
    File::Slurper::Temp::write_binary(
        $recipe_file,
        YAML::XS::Dump(
            {
                _base => {
                    _global   => { data_source => "$tmpdir/data" },
                    registrar => { type        => 'easydns', user => 'somebody', key => 'secret:dns/registrar/password' },
                },
                $REMOTE => { letsencrypt => undef },
            }
        )
    );

    Provisioner::Cookbook->forget();

    my $err = exception {
        Trog::Provisioner::Config::Generator::main( '--ipmap', $ipmap_file, '--recipes', $recipe_file, '--secrets', $kdbx, '--skip_ssh', $REMOTE );
    };
    is( $err, undef, 'the generation runs to the end' ) or diag $err;

    my $hook = "$tmpdir/domains/$REMOTE/domain.hook";
    ok( -f $hook, 'a dehydrated hook was written' ) or return;

    # bin/new_config resolves secret: references into a clone of the
    # configuration, and a recipe reading a sibling's credential through
    # Provisioner::Cookbook was answered from the copy that had not been
    # resolved -- so the hook exported the reference and authenticated with
    # nothing.
    my $text = File::Slurper::read_text($hook);
    like( $text, qr/^export[ ]LEXICON_EASYDNS_AUTH_TOKEN="REAL-PASSWORD"$/m, 'the hook carries the password the store holds' );
    unlike( $text, qr/secret:/, 'and nowhere in it says where the password is instead of what it is' );
};

subtest 'a reserved name resolves the interface to the server on the guest' => sub {
    my ( $err, $makefile ) = generate( $LOCAL, letsencrypt => undef );

    is( $err, undef, 'the generation runs to the end' )   or diag $err;
    ok( defined $makefile, 'and a makefile was written' ) or return;

    # No public registrar holds a zone under a TLD RFC 2606 reserves, so there
    # is only ever the one candidate and nothing has to say which.
    ok( builds( $makefile,  'pdns' ),      'pdns is built, because the guest answers for itself' );
    ok( !builds( $makefile, 'registrar' ), 'and the registrar recipe is not' );
};

subtest 'a name somebody else holds resolves it to the registrar' => sub {
    my ( $err, $makefile, $dir ) = generate(
        $REMOTE,
        letsencrypt => undef,
        registrar   => { type => 'easydns', user => 'somebody', key => 'a-token' },
    );

    is( $err, undef, 'the generation runs to the end' )   or diag $err;
    ok( defined $makefile, 'and a makefile was written' ) or return;

    # The registrar installs nothing of its own, so it has no target to find.
    # What reaches the guest from it is the lexicon shortcut, rendered out of the
    # credentials it holds -- which is what the dependency is for.
    ok( builds( $makefile,  'lexicon' ), 'lexicon is built, being what carries those credentials onto the guest' );
    ok( !builds( $makefile, 'pdns' ),    'and no server of our own, since somebody else holds the zone' );

    my $shortcut = -f "$dir/lexicon.sh" ? File::Slurper::read_text("$dir/lexicon.sh") : q{};
    like( $shortcut, qr/^export[ ]LEXICON_EASYDNS_AUTH_TOKEN=/m, 'and lexicon is pointed at the registrar that holds the zone' );
};

subtest 'a guest that could answer either way is refused until it says which' => sub {
    my ( $err, undef ) = generate(
        $REMOTE,
        letsencrypt => undef,
        registrar   => { type    => 'easydns', user => 'somebody', key => 'a-token' },
        pdns        => { api_key => 'an-api-key' },
    );

    ok( $err, 'the generation stops' ) or return;
    like( $err, qr/dns_preference/, 'naming the key that settles it' );

    # And settles when it does.  The preference is read from the configuration
    # of whichever recipe declared the dependency, which is where an operator
    # already writes it.
    my ( $ok, $makefile, $dir ) = generate(
        $REMOTE,
        letsencrypt => { dns_preference => 'registrar' },
        registrar   => { type           => 'easydns', user => 'somebody', key => 'a-token' },
        pdns        => { api_key        => 'an-api-key' },
    );

    is( $ok, undef, 'naming one lets it through' ) or diag $ok;
    ok( builds( $makefile, 'lexicon' ), 'and lexicon is built' );

    # The tie has to be settled where the shortcut is rendered, not only in the
    # recipe declaring the key: lexicon resolves the provider for itself, and on
    # a guest configured both ways it has the same tie and nothing of its own to
    # break it.  letsencrypt hands its answer down, and this is that arriving.
    my $shortcut = -f "$dir/lexicon.sh" ? File::Slurper::read_text("$dir/lexicon.sh") : q{};
    like( $shortcut, qr/^export[ ]LEXICON_EASYDNS_AUTH_TOKEN=/m, 'and the one named is what lexicon is pointed at' );
};

done_testing;
