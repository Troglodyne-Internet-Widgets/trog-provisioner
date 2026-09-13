#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-DNSRecipe.t - what a recipe that can answer a dns-01 challenge has
to say for itself

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

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
    is( Provisioner::DNSRecipe->default_implementation, 'pdns', 'and is what a guest uses when nothing says otherwise' );
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
    like( $out, qr{^export LEXICON_POWERDNS_PDNS_SERVER="/var/spool/powerdns/api\.sock"$}m, 'the socket, under the name lexicon resolves' );
    unlike( $out, qr{^export LEXICON_POWERDNS_SERVER=}m, 'and not the one it ignores' );

    like( $out, qr{^export LEXICON_POWERDNS_AUTH_TOKEN="an-api-key"$}m, 'the token' );
    unlike( $out, qr{AUTH_USERNAME}, 'and no empty username, since this provider takes none' );

    like( $out, qr{^lexicon --resolve-zone-name powerdns }m, 'invoked with the flag the provider needs' );
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

Test::NoWarnings::had_no_warnings();

done_testing;
