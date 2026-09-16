#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-DNSRecipe.t - what a recipe that can answer a dns-01 challenge has
to say for itself

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use Test::MockModule();
use File::Temp qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();
use Provisioner::DNSRecipe();

# Loaded at compile time so its API_SOCKET is a declared global rather than a
# name this file mentions once: `warnings FATAL => 'all'` turns that `once`
# warning into a compile error, and the file never runs at all.
use Provisioner::Recipe::pdns();

# A fresh recipe per case: validated() memoises onto the object, so a second
# render through the same one answers with the first one's options.
sub fresh {
    my ($name) = @_;

    return Provisioner::Cookbook->load( $name, distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

my $DOMAIN = 'dns.test.test';

subtest 'the interface refuses to guess how a provider is reached' => sub {

    # A subclass that answered nothing would otherwise render a hook exporting
    # no credential at all, which fails in the middle of an order rather than
    # at the point somebody could still fix it.
    like(
        exception { Provisioner::DNSRecipe->lexicon_credentials() },
        qr/lexicon_credentials/,
        'naming the method it did not answer'
    );
    like(
        exception { Provisioner::DNSRecipe->lexicon_credentials() },
        qr/Provisioner::DNSRecipe/,
        'and where the contract is written down'
    );
};

subtest 'pdns is one of them, and is still a recipe' => sub {
    my $class = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' );

    ok( $class->isa('Provisioner::DNSRecipe'), 'the distro subclass reaches the interface' );
    ok( $class->isa('Provisioner::Recipe'),    'and is still a recipe, which is what Cookbook->load asserts' );
    is( Provisioner::DNSRecipe->local_implementation, 'pdns', 'and is the implementation that runs on the guest itself' );
};

subtest 'what pdns tells lexicon' => sub {
    my %creds = fresh('pdns')->lexicon_credentials( api_key => 'an-api-key' );

    is( $creds{type}, 'powerdns',            'the provider lexicon knows it by' );
    is( $creds{key},  'an-api-key',          'authenticating with the key the server runs with' );
    is( $creds{opts}, '--resolve-zone-name', 'and resolving the zone rather than composing it' );

    # The socket is named once, by the recipe that binds it.
    my ($server) = grep { $_->{key} eq 'PDNS_SERVER' } @{ $creds{extra} // [] };
    ok( $server, 'the API endpoint is handed over as a provider option' ) or return;
    is( $server->{value}, $Provisioner::Recipe::pdns::API_SOCKET, 'naming the socket this recipe binds' );
};

subtest 'the shortcut is rendered from that, and names what lexicon reads' => sub {
    my $out = fresh('pdns')->render_file( 'files/lexicon.shortcut.sh.tt', domain => $DOMAIN, api_key => 'an-api-key' );

    # lexicon builds an environment variable from provider plus option, so
    # --pdns-server is LEXICON_POWERDNS_PDNS_SERVER.  Its legacy fallback only
    # strips _AUTH_, so the shorter spelling resolved to nothing and this
    # shortcut asked the default endpoint of a server that has none.
    like( $out, qr{^export[ ]LEXICON_POWERDNS_PDNS_SERVER="/var/spool/powerdns/api\.sock"$}m, 'the socket, under the name lexicon resolves' );    ## no critic (RegularExpressions::ProhibitComplexRegexes)
    unlike( $out, qr{^export[ ]LEXICON_POWERDNS_SERVER=}m, 'and not the one it ignores' );

    like( $out, qr{^export[ ]LEXICON_POWERDNS_AUTH_TOKEN="an-api-key"$}m, 'the token' );
    unlike( $out, qr{AUTH_USERNAME}, 'and no empty username, since this provider takes none' );

    like( $out, qr{^lexicon[ ]--resolve-zone-name[ ]powerdns[ ]}m, 'invoked with the flag the provider needs' );
};

subtest 'the operator registrar is left alone, so synczones still has an upstream' => sub {

    # synczones writes /etc/synczones.conf out of registrar, which is whoever
    # holds the public zone this guest syncs up to.  The credentials above
    # belong to the guest itself, so they go under their own key: written into
    # registrar they would have the guest name itself as its own upstream.
    my $conf = fresh('pdns')->render_file(
        'files/pdns.synczones.tt',
        domain    => $DOMAIN,
        api_key   => 'an-api-key',
        registrar => { type => 'easydns', user => 'somebody', key => 'a-token' },
    );

    like( $conf, qr/^\[powerdns\]$/m,           'the local server is a section' );
    like( $conf, qr/^\[easydns\]$/m,            'and the registrar it syncs up to is another' );
    like( $conf, qr/^auth_username=somebody$/m, 'carrying the credentials the operator set' );

    my $alone = fresh('pdns')->render_file( 'files/pdns.synczones.tt', domain => $DOMAIN, api_key => 'an-api-key' );
    unlike( $alone, qr/^\[easydns\]$/m, 'while a guest with no registrar syncs nowhere' );
};

subtest 'the CA depends on the capability, not on a recipe name' => sub {
    my %common = ( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'doge' );

    my %required = fresh('acmeca')->required_recipes(%common);
    my $local    = Provisioner::DNSRecipe->local_implementation;
    ok( exists $required{$local}, "the CA requires whatever runs the DNS on the guest ($local)" );

    my %handed = $required{$local} ? $required{$local}->() : ( sentinel => 1 );
    is_deeply( \%handed, {}, 'and hands it nothing, since its key is the operator to supply' );

    # Following the interface rather than a literal, which is the whole of #149.
    # Asserting the key is 'pdns' would pass just as well against the hardcoded
    # string it replaced, so this moves the answer and checks the CA moved with
    # it.
    my $iface = Test::MockModule->new('Provisioner::DNSRecipe');
    $iface->redefine( local_implementation => sub { return 'registrar' } );

    my %moved = fresh('acmeca')->required_recipes(%common);
    ok( exists $moved{registrar}, 'so moving the answer moves what the CA asks for' );
    ok( !exists $moved{pdns},     'and it stops asking for the one it used to name' );
};

subtest 'the interface says which implementation serves a domain' => sub {

    # Handed the configuration rather than left to find it.  It used to ask
    # Provisioner::Cookbook, which answers about the installation -- and the
    # generator is routinely pointed at a different recipes file, so the
    # resolver and the run could be looking at two different configurations.
    # Passing it also means these cases are data rather than mocking.
    my $nothing   = {};
    my $registrar = { registrar => { type => 'easydns' } };
    my $both      = { registrar => { type => 'easydns' }, pdns => { api_key => 'k' } };

    # A reserved name is served by the guest, because no public registrar holds
    # a zone under a TLD RFC 2606 reserves.
    is( Provisioner::DNSRecipe->implementation_for( domain => 'a.test', configured => $nothing ), 'pdns', 'a reserved name is served locally' );

    like(
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'a.troglodyne.net', configured => $nothing ) },
        qr/no[ ]DNS[ ]provider/,
        'and a public one with nothing configured is refused rather than guessed at'
    );

    is( Provisioner::DNSRecipe->implementation_for( domain => 'a.troglodyne.net', configured => $registrar ), 'registrar', 'the one that is configured serves it' );

    like(
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'a.test', configured => $registrar, dns_preference => 'registrar' ) },
        qr/reserve/,
        'while naming a registrar for a reserved name is refused'
    );

    like(
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'a.troglodyne.net', configured => $both ) },
        qr/dns_preference/,
        'a guest that could answer either way is asked which'
    );

    foreach my $named (qw{pdns registrar}) {
        is( Provisioner::DNSRecipe->implementation_for( domain => 'a.troglodyne.net', configured => $both, dns_preference => $named ), $named, "naming $named settles it" );
    }

    # A domain layered onto another is served by what that guest runs, so the
    # host's configuration counts as well as its own.
    is(
        Provisioner::DNSRecipe->implementation_for( domain => 'tenant.troglodyne.net', configured => $nothing, host_configured => $registrar ),
        'registrar',
        'and a tenant is served by what its host holds'
    );

    # The machine's name, so a refusal says which guest was looked at rather
    # than naming the domain that was never going to have a server of its own.
    like(
        exception {
            Provisioner::DNSRecipe->implementation_for(
                domain         => 'tenant.troglodyne.net',
                configured     => $nothing,
                host           => 'host.troglodyne.net',
                dns_preference => 'pdns',
            );
        },
        qr/host\.troglodyne\.net[ ]is[ ]configured[ ]with[ ]no[ ]pdns/,
        'and a refusal names the machine it asked about, not the domain on it'
    );

    like(
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'a.troglodyne.net' ) },
        qr/was[ ]not[ ]told[ ]what/,
        'asked without a configuration at all, it says so rather than resolving against something else'
    );
};

subtest 'the interface names the key that settles a tie' => sub {

    # bin/new_config reads this out of the configuration of whichever recipe
    # declared the dependency, so it can resolve one without knowing what DNS is.
    is( Provisioner::DNSRecipe->tiebreaker_key, 'dns_preference', 'which is where operators already write it' );

    my %schema = Provisioner::Cookbook->load('letsencrypt')->args();
    ok( exists $schema{properties}{ Provisioner::DNSRecipe->tiebreaker_key }, 'and the recipe that takes it declares it' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
