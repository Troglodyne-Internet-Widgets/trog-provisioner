#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-registrar.t - which server holds the zone of a domain, how
lexicon reaches it, and what is published there

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use Test::MockModule();
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();

use FindBin::libs;

use Provisioner::Cookbook();

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

    # Through the lexicon recipe, which is what installs the shortcut: it asks
    # the registrar who holds this zone and renders whatever that answers.  The
    # configuration is mocked so the token is one to assert on, rather than the
    # one pdns mints for a server nobody configured a key for.
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    $conf->redefine( domain_config => sub { return { pdns => { api_key => 'an-api-key' } } } );
    $conf->redefine( host_of       => sub { return } );

    my $out = fresh('lexicon')->render_file( 'files/lexicon.shortcut.sh.tt', domain => $DOMAIN );

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

# Makes $conf, a mock of Provisioner::Cookbook, answer with two guests: $name
# names $authority as the authority of its registrar, and $authority runs pdns
# and holds its own zone.
sub authority_conf {
    my ( $conf, $name, $authority, %over ) = @_;

    $conf->redefine(
        domain_config => sub {
            my ( undef, $domain ) = @_;
            return { pdns => {}, registrar => { authority => $authority }, %{ $over{authority_conf} // {} } } if $domain eq $authority;
            return { registrar => { type => 'easydns', key => 'a-registrar-key', authority => $authority } } if $domain eq $name;
            return {};
        }
    );
    $conf->redefine( host_of => sub { return } );
    return;
}

subtest 'a domain that names an authority reaches it with a token of its own' => sub {
    my $name = 'web.lab.example.net';
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    authority_conf( $conf, $name, 'ns.example.net' );

    my $registrar = Provisioner::Cookbook->load('registrar');
    is( $registrar->delegated_to($name),            'ns.example.net', 'its authority is the guest that its registrar names' );
    is( $registrar->delegated_to('ns.example.net'), undef,            'and a guest that names none has none' );

    my %creds = $registrar->lexicon_credentials( type => 'easydns', key => 'a-registrar-key', domain => $name );
    is( $creds{type},     'powerdns',                 'the pdns guest, whatever the registrar of the domain is' );
    is( $creds{key_file}, "/etc/lexicon/$name.token", 'with the token in a file' );
    is( $creds{key},      q{},                        'and not in the payload' );

    my %secrets = fresh('registrar')->guest_secrets( '/bogus', $name );
    is_deeply( [ keys %secrets ], ["/etc/lexicon/$name.token"], 'which bin/provision puts on the guest' );
    is( $secrets{"/etc/lexicon/$name.token"}{issue}{guest}, 'ns.example.net', 'from the authority, which issues it' );
    is_deeply( { fresh('registrar')->guest_secrets( '/bogus', 'web.example.net' ) }, {}, 'and a domain that names no authority needs none' );

    my $out        = fresh('lexicon')->render_file( 'files/lexicon.shortcut.sh.tt', domain => $name, install_dir => '/bogus', admin_user => 'someadmin' );
    my $token_line = qq{export LEXICON_POWERDNS_AUTH_TOKEN="\$(cat /etc/lexicon/$name.token)"};
    like( $out, qr{^\Q$token_line\E$}m, 'the shortcut reads the token from the file' );
    my $server_line = 'export LEXICON_POWERDNS_PDNS_SERVER="https://dnsapi.ns.example.net"';
    like( $out, qr{^\Q$server_line\E$}m, 'at the proxy of that guest' );

    my $hook = fresh('letsencrypt')->render_file( 'files/ssl.dehydrated.hook.tt', domain => $name, install_dir => '/bogus', admin_user => 'someadmin' );
    like( $hook, qr{^\Q$token_line\E$}m, 'and so does the hook that answers a challenge' );

    like( exception { $registrar->lexicon_credentials( domain => 'web.example.net' ) }, qr/no[ ]type/, 'a domain that names no authority needs the type of its registrar' );
};

subtest 'what a guest that names an authority sets up' => sub {
    my $name = 'web.lab.example.net';
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    authority_conf( $conf, $name, 'ns.example.net' );
    my %common = ( domain => $name, install_dir => '/bogus', admin_user => 'someadmin', script_dir => '/bogus/bin', main_ip => '192.0.2.6', ipmap => { 'ns.example.net' => '192.0.2.53' } );

    my %opts = fresh('registrar')->validate( %common, authority => 'ns.example.net', type => 'easydns' );
    is( $opts{authority_address}, '192.0.2.53',             'it asks the authority at its address' );
    is( $opts{routing_domains},   "~$name ~ns.example.net", 'for its own zone, and for the zone of the authority, which the authority holds' );
    is( $opts{upstream}{type},    'easydns',                'the NS record of its zone goes to its registrar' );
    is( $opts{parent},            'lab.example.net',        'through a shortcut that names the zone above' );
    ok( !$opts{fleet_anchor}, 'and an authority under a public name needs no anchor' );

    my $fragment = fresh('registrar')->render( %common, authority => 'ns.example.net', type => 'easydns' );
    my $dropin   = 'install -o root -g root -m 0644 registrar-resolved.conf /etc/systemd/resolved.conf.d/trog-authority.conf';
    my $delegate = "publish_dns_records --delegate --shortcut /opt/lexicon/upstream/$name $name ns.example.net";
    like( $fragment, qr{^\Q$dropin\E$}m,                                               'the fragment routes those names to the authority' );
    like( $fragment, qr{^POSTRUN_SLOT=0[ ]\S+queue_postrun_task[ ]\S+\Q$delegate\E$}m, 'and delegates its zone to the authority first in the postrun, before the fetcher of letsencrypt' );
    ok( index( $fragment, '--delegate' ) < index( $fragment, "publish_dns_records $name" ), 'before it publishes its records there' );
    unlike( $fragment, qr/--nameserver/, 'and publishes no ns1, because the authority is its nameserver' );

    my $resolved = fresh('registrar')->render_file( 'files/registrar.resolved.tt', %common, authority => 'ns.example.net', type => 'easydns' );
    like( $resolved, qr/^DNS=192[.]0[.]2[.]53$/m,                     'the drop-in names the authority' );
    like( $resolved, qr/^Domains=~\Q$name\E[ ]~ns[.]example[.]net$/m, 'for those zones alone' );

    # An authority whose own name a public registrar holds refuses a query for
    # it, so the guest asks a public resolver for that name instead.
    authority_conf( $conf, $name, 'ns.example.net', authority_conf => { registrar => { type => 'easydns' } } );
    my %public = fresh('registrar')->validate( %common, authority => 'ns.example.net', type => 'easydns' );
    is( $public{routing_domains}, "~$name", 'and the zone of an authority that leaves its own name to a registrar is not routed to it' );

    like( exception { fresh('registrar')->validate( %common, domain => 'example.net', authority => 'ns.example.net', type => 'easydns' ) }, qr/fewer[ ]than[ ]three[ ]labels/, 'a registered domain cannot name an authority' );
    like( exception { fresh('registrar')->validate( %common, ipmap  => {},            authority => 'ns.example.net', type => 'easydns' ) }, qr/no[ ]address/,                  'nor can a domain whose authority has no address' );
};

subtest 'a guest that holds its own zone is delegated as one under another guest is' => sub {
    my $name = 'web.lab.example.net';
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    $conf->redefine( domain_config => sub { my ( undef, $domain ) = @_; return $domain eq $name ? { pdns => {} } : {} } );
    $conf->redefine( host_of       => sub { return } );
    my %common = ( domain => $name, install_dir => '/bogus', admin_user => 'someadmin', script_dir => '/bogus/bin', main_ip => '192.0.2.6', ipmap => { $name => '192.0.2.6' }, authority => $name, type => 'easydns' );

    my %opts = fresh('registrar')->validate(%common);
    is( $opts{upstream}{type}, 'easydns',         'the NS record of its zone goes to its registrar' );
    is( $opts{parent},         'lab.example.net', 'through a shortcut that names the zone above' );
    ok( !exists $opts{authority}, 'and it routes nothing to an authority, because it is its own' );

    my $fragment = fresh('registrar')->render(%common);
    my $delegate = "publish_dns_records --delegate --shortcut /opt/lexicon/upstream/$name $name ns1.$name 192.0.2.6";
    like( $fragment, qr{^POSTRUN_SLOT=0[ ]\S+queue_postrun_task[ ]\S+\Q$delegate\E$}m, 'the zone above names its ns1 first in the postrun, with the address of ns1 as glue, because ns1 is inside the zone' );
    my $records = "publish_dns_records --nameserver ns1.$name $name 192.0.2.6";
    like( $fragment, qr{\Q$records\E$}m, 'its own records include ns1, at the address of the domain' );
    ok( index( $fragment, '--delegate' ) < index( $fragment, $records ), 'and go up after the delegation' );

    # A guest behind NAT publishes another address, and every record that a
    # resolver follows to its nameserver must give that one.
    my $natted = fresh('registrar')->render( %common, address => '198.51.100.6' );
    like( $natted, qr{\Q$name\E[ ]ns1[.]\Q$name\E[ ]198[.]51[.]100[.]6$}m, 'the glue is the address that its A record publishes' );
    my $own_ns1 = "--nameserver ns1.$name $name 198.51.100.6";
    like( $natted, qr{\Q$own_ns1\E$}m, 'and so is the record of ns1 in its own zone' );

    my %untyped = %common;
    delete $untyped{type};
    like( exception { fresh('registrar')->validate(%untyped) }, qr/no[ ]type/, 'without the registrar of the zone above, it is refused' );
    like(
        exception { fresh('registrar')->validate( %common, domain => 'example.net', authority => 'example.net', ipmap => { 'example.net' => '192.0.2.6' } ) },
        qr/fewer[ ]than[ ]three[ ]labels/,
        'as a registered domain is, which needs glue at the registry'
    );
    like( exception { fresh('registrar')->validate( %common, main_ip => undef ) }, qr/inside[ ]its[ ]zone/, 'and so is one with no address for its ns1' );

    # An authority whose name is inside the zone that it holds needs glue too.
    my $inside = "ns.$name";
    authority_conf( $conf, $name, $inside );
    like(
        fresh('registrar')->render( %common, authority => $inside, ipmap => { $inside => '192.0.2.53' } ),
        qr{\Q$name\E[ ]\Q$inside\E[ ]192[.]0[.]2[.]53$}m,
        'an authority inside the zone gets its address as glue'
    );
};

subtest 'the authority is built first, as any guest that a setting names is' => sub {
    my %conf = ( 'ns.test.test' => { pdns => {} }, 'web.lab.test.test' => { registrar => { authority => 'ns.test.test' } } );

    is_deeply(
        [ Provisioner::Cookbook->named_guests( 'web.lab.test.test', \%conf ) ],
        [ { domain => 'ns.test.test', setting => 'registrar.authority', by => 'web.lab.test.test', weak => 0 } ],
        'the setting names the authority, and the guest needs it to build'
    );
    is_deeply( [ Provisioner::Cookbook->upstream_domains( 'web.lab.test.test', \%conf ) ], ['ns.test.test'], 'so bin/provision builds the authority first' );
};

subtest 'a domain whose authority is under a reserved TLD trusts the authority of its API' => sub {
    my $name = 'web.lab.zone.test';
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    authority_conf( $conf, $name, 'ns.zone.test' );

    my $dir    = tempdir( CLEANUP => 1 );
    my $anchor = "$dir/authority.crt";
    File::Slurper::Temp::write_text( $anchor, "the authority\n" );
    my $fetchcache = Test::MockModule->new( Provisioner::Cookbook->load('fetchcache') );
    $fetchcache->redefine( authority => sub { return { cert => $anchor, key => '/bogus' } } );

    my %common = ( domain => $name, install_dir => '/bogus', admin_user => 'someadmin', script_dir => '/bogus/bin', main_ip => '192.0.2.6', ipmap => { 'ns.zone.test' => '192.0.2.53' }, authority => 'ns.zone.test' );
    my $out    = tempdir( CLEANUP => 1 );
    my @wrote  = fresh('registrar')->generate_files( $out, %common );

    ok( ( grep { $_ eq 'registrar-anchor.crt' } @wrote ), 'the payload carries the authority' );
    is( File::Slurper::read_text("$out/registrar-anchor.crt"), "the authority\n", 'which is the fleet authority' );
    my $install = 'install -o root -g root -m 0644 registrar-anchor.crt /usr/local/share/ca-certificates/trog-acmeca.crt';
    like( fresh('registrar')->render(%common), qr{^\Q$install\E$}m, 'and the fragment installs it where acmeca installs the same one' );
    unlike( fresh('registrar')->render(%common), qr{--delegate}, 'and under a reserved TLD there is no zone above to delegate from' );
};

subtest 'which server holds the zone' => sub {
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    my %configured;
    my %host;
    $conf->redefine( domain_config => sub { my ( undef, $domain ) = @_; return $configured{$domain} // {} } );
    $conf->redefine( host_of       => sub { my ( undef, $domain ) = @_; return $host{$domain} } );

    my $registrar = Provisioner::Cookbook->load('registrar');
    my $holder    = sub { return $registrar->authority_of(shift) // 'the registrar' };

    # No public registrar holds a zone under a TLD RFC 2606 reserves.
    is( $holder->('a.test'),        'a.test',        'a reserved name is held by the guest itself' );
    is( $holder->('a.example.net'), 'the registrar', 'and a public one by the registrar of type' );

    # A pdns guest can be the authority of other guests while a registrar holds
    # its own name.
    $configured{'ns.example.net'} = { pdns => {}, registrar => { type => 'easydns' } };
    is( $holder->('ns.example.net'), 'the registrar', 'a guest that runs pdns leaves its own name to the registrar' );
    ok( !$registrar->serves_itself('ns.example.net'), 'and does not serve itself' );

    $configured{'b.example.net'} = { pdns => {}, registrar => { type => 'easydns', authority => 'b.example.net' } };
    is( $holder->('b.example.net'), 'b.example.net', 'while one that names itself holds its own zone, whatever registrar it inherits' );

    $configured{'web.c.test'} = { registrar => { authority => 'NS.C.test.' } };
    is( $holder->('web.c.test'), 'ns.c.test', 'an authority holds the zone of a guest that names it, however it is spelled' );

    $configured{'web.d.example.net'} = { pdns => {}, registrar => { authority => 'ns.d.example.net' } };
    is( $holder->('web.d.example.net'), 'ns.d.example.net', 'also of a guest that runs a pdns of its own for other guests' );

    $configured{'e.example.net'} = { registrar => { authority => 'e.example.net' } };
    is( $holder->('e.example.net'), 'e.example.net', 'and a guest can name itself' );
    ok( $registrar->serves_itself('e.example.net'), 'which then serves itself' );
    is( $registrar->delegated_to('e.example.net'), undef, 'and is delegated to nobody' );

    # A domain layered onto another is served by what that guest runs.
    $host{'tenant.example.net'} = 'b.example.net';
    is( $holder->('tenant.example.net'), 'b.example.net', 'a tenant is held by its host, which holds its own zone' );
    ok( $registrar->serves_itself('tenant.example.net'), 'which counts as serving itself' );

    $host{'tenant.c.test'} = 'web.c.test';
    is( $holder->('tenant.c.test'), 'ns.c.test', 'and by the authority that its host names' );
};

subtest 'a guest that serves itself must run a server, as an authority elsewhere must' => sub {
    my %configured = ( 'web.lab.test' => { registrar => { authority => 'ns.test' } } );
    my %host;
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    $conf->redefine( domain_config => sub { my ( undef, $domain ) = @_; return $configured{$domain} // {} } );
    $conf->redefine( host_of       => sub { my ( undef, $domain ) = @_; return $host{$domain} } );

    my %common = ( install_dir => '/opt/domains', admin_user => 'someadmin' );

    # Measured on a scratch guest: a pdns of its own made its recursor answer
    # for its zone, nostubresolver bypassed the route to the authority, and the
    # name of the API of the authority did not resolve.
    foreach my $domain ( $DOMAIN, 'web.lab.test' ) {
        my %required = fresh('registrar')->required_recipes( %common, domain => $domain );
        ok( !exists $required{pdns},   "$domain gets no pdns from its registrar" );
        ok( exists $required{lexicon}, 'but gets lexicon, which publishes the records' );
    }

    my %enrich = ( %common, domain => $DOMAIN, ipmap => { 'ns.test' => '192.0.2.53' } );
    is(
        exception { fresh('registrar')->enrich(%enrich) },
        "$DOMAIN is the authority of its registrar, but runs no pdns.  Add pdns to $DOMAIN.\n",
        'a reserved name that runs no pdns is refused, and told to add it'
    );
    is(
        exception { fresh('registrar')->enrich( %enrich, domain => 'web.lab.test' ) },
        "web.lab.test names ns.test as the authority of its registrar, but ns.test runs no pdns in this installation.\n",
        'as is a guest whose authority runs none'
    );

    $configured{$DOMAIN} = { pdns => {} };
    is( exception { fresh('registrar')->enrich(%enrich) }, undef, 'and one that runs pdns is not' );

    # A tenant holds its zone on the machine of its host.
    $host{'tenant.test'} = $DOMAIN;
    is( exception { fresh('registrar')->enrich( %enrich, domain => 'tenant.test' ) }, undef, 'nor is a tenant whose host runs pdns' );
    delete $configured{$DOMAIN};
    is(
        exception { fresh('registrar')->enrich( %enrich, domain => 'tenant.test' ) },
        "tenant.test is on $DOMAIN, which is the authority of its registrar, but $DOMAIN runs no pdns.  Add pdns to $DOMAIN.\n",
        'and a tenant whose host runs none is told to add it to the host'
    );

    # lexicon walks the zone through the system resolver for --resolve-zone-name,
    # and step-ca validates dns-01 through it too.  On the stub the guest cannot
    # resolve its own zone.
    my %server = fresh('pdns')->required_recipes( %common, domain => $DOMAIN );
    ok( exists $server{nostubresolver}, 'and the server brings a resolver that can see the zone' );
};

subtest 'a domain that no server holds is refused' => sub {
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    $conf->redefine( domain_config => sub { return {} } );
    $conf->redefine( host_of       => sub { return } );

    like(
        exception { Provisioner::Cookbook->load('registrar')->credentials_for( domain => 'a.example.net' ) },
        qr/no[ ]type[ ]for[ ]a[.]example[.]net/,
        'naming the domain, rather than rendering a hook that cannot run'
    );
    like(
        exception { fresh('registrar')->validate( domain => 'a.example.net', install_dir => '/bogus', admin_user => 'someadmin' ) },
        qr/no[ ]type/,
        'and the registrar itself refuses to build it'
    );
};

subtest 'each recipe that is handed the names declares them' => sub {
    foreach my $recipe (qw{registrar letsencrypt}) {
        my %schema = Provisioner::Cookbook->load($recipe)->schema;
        is( $schema{properties}{hostnames}{type}, 'array', "$recipe has the hostnames option" );
    }

    # The schema refuses a key that nothing declares, so a recipe that
    # is handed no names must not declare them.
    my %nginx = Provisioner::Cookbook->load('nginx')->schema;
    ok( !exists $nginx{properties}{hostnames}, 'and a recipe that is handed none does not' );
};

# What the registrar publishes.  The configuration is mocked, because the
# configuration says which server holds the zone.
sub publishing {
    my ( $name, $configured, %opts ) = @_;

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( domain_config => sub { return $configured } );
    $cookbook->redefine( host_of       => sub { return } );

    my $recipe = fresh($name);
    my %common = ( install_dir => '/bogus', admin_user => 'someadmin', script_dir => '/root/bin', %{ $configured->{$name} // {} } );
    return ( { $recipe->validate( %common, %opts ) }, fresh($name)->render( %common, %opts ) );
}

my $PUBLIC    = 'pub.example.net';
my $REGISTRAR = { registrar => { type => 'easydns' } };
my %ON_PUBLIC = ( domain => $PUBLIC, main_ip => '192.0.2.50', aliases => { $PUBLIC => ["alt.$PUBLIC"] }, hostnames => ["www.$PUBLIC"] );

subtest 'the registrar publishes the records of the domain' => sub {
    my ( $opts, $fragment ) = publishing( 'registrar', $REGISTRAR, %ON_PUBLIC );

    is( $opts->{publish_records}, 1, 'into the zone that a registrar holds' );
    my $queued = qr/queue_postrun_task[ ]\S+publish_dns_records[ ]/;
    like( $fragment, qr/${queued}\Q$PUBLIC\E[ ]192[.]0[.]2[.]50[ ]/, 'in the postrun, with the address the guest was built with' );
    like( $fragment, qr/[ ]alt[.]\Q$PUBLIC\E[ ]www[.]\Q$PUBLIC\E$/m, 'and each name: the configured aliases and the names that recipes handed over, sorted' );
    unlike( $fragment, qr/--nameserver/, 'and no nameserver, because the registrar has its own' );

    # Through the shortcut, which points at the pdns of the guest, and not at
    # the registrar that the guest inherits.
    my ($own) = publishing( 'registrar', { %$REGISTRAR, pdns => { api_key => 'k' } }, %ON_PUBLIC );
    is( $own->{publish_records}, 1, 'and into the zone that the pdns of the guest holds' );
    ok( !exists $own->{authority}, 'which is no authority of its own, so nothing is delegated' );

    my ($reserved) = publishing( 'registrar', { pdns => {} }, %ON_PUBLIC, domain => $DOMAIN, aliases => {}, hostnames => [] );
    is( $reserved->{publish_records}, 1, 'and for a name under a reserved TLD, which only the guest can serve' );
};

subtest 'the address of the A record' => sub {
    my ($allocated) = publishing( 'registrar', $REGISTRAR, %ON_PUBLIC, main_ip => undef );
    is( $allocated->{publish_records}, 0, 'nothing is published where the hypervisor allocates the address' );

    my ( undef, $fragment ) = publishing( 'registrar', $REGISTRAR, %ON_PUBLIC, address => '203.0.113.7' );
    like( $fragment, qr/\Q$PUBLIC\E[ ]203[.]0[.]113[.]7[ ]/, 'an address that the domain names replaces the one it was built with' );
    unlike( $fragment, qr/192[.]0[.]2[.]50/, 'which is not published' );

    my ($named) = publishing( 'registrar', $REGISTRAR, %ON_PUBLIC, main_ip => undef, address => '203.0.113.7' );
    is( $named->{publish_records}, 1, 'and a guest whose address the hypervisor allocates publishes one that the domain names' );

    ok( exception { publishing( 'registrar', $REGISTRAR, %ON_PUBLIC, address => "gateway.$PUBLIC" ) }, 'an address that is not IPv4 is refused' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
