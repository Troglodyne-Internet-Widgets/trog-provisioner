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
use File::Slurper();
use File::Slurper::Temp();

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

    # Through the lexicon recipe, which is what installs the shortcut: it asks
    # the interface who holds this zone and renders whatever that answers.  The
    # configuration is mocked so the token is one to assert on, rather than the
    # one pdns mints for a server nobody configured a key for.
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    $conf->redefine( domain_config => sub { return { pdns => { api_key => 'an-api-key' } } } );

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
# names $authority as the authority of its registrar, and $authority runs pdns.
sub authority_conf {
    my ( $conf, $name, $authority, %over ) = @_;

    $conf->redefine(
        domain_config => sub {
            my ( undef, $domain ) = @_;
            return { pdns      => {}, %{ $over{authority_conf} // {} } }                                     if $domain eq $authority;
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
    authority_conf( $conf, $name, 'ns.example.net', authority_conf => { lexicon => { dns_preference => 'pdns' } } );
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
    like( $fragment, qr{^\Q$dropin\E$}m,  'the fragment routes those names to the authority' );
    like( $fragment, qr{\Q$delegate\E$}m, 'and delegates its zone to the authority in the postrun' );
    ok( index( $fragment, '--delegate' ) < index( $fragment, "publish_dns_records $name" ), 'before it publishes its records there' );

    my $resolved = fresh('registrar')->render_file( 'files/registrar.resolved.tt', %common, authority => 'ns.example.net', type => 'easydns' );
    like( $resolved, qr/^DNS=192[.]0[.]2[.]53$/m,                     'the drop-in names the authority' );
    like( $resolved, qr/^Domains=~\Q$name\E[ ]~ns[.]example[.]net$/m, 'for those zones alone' );

    like( exception { fresh('registrar')->validate( %common, domain => 'example.net', authority => 'ns.example.net', type => 'easydns' ) }, qr/fewer[ ]than[ ]three[ ]labels/, 'a registered domain cannot name an authority' );
    like( exception { fresh('registrar')->validate( %common, ipmap  => {},            authority => 'ns.example.net', type => 'easydns' ) }, qr/no[ ]address/,                  'nor can a domain whose authority has no address' );
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

subtest 'lexicon settles the tie itself where no letsencrypt hands it one' => sub {

    # letsencrypt resolves the provider and hands it down through
    # required_recipes, so a guest running it needs nothing under lexicon.  pdns
    # and registrar each require lexicon and hand it nothing, so a guest with
    # both of them and no letsencrypt has the same tie and nobody to settle it.
    # That is the case this key exists for, and the one the schema description
    # used to tell an operator they would never meet.
    my $conf = Test::MockModule->new('Provisioner::Cookbook');
    $conf->redefine( domain_config => sub { return { pdns => { api_key => 'a-key' }, registrar => { type => 'easydns', key => 'a-token' } } } );
    $conf->redefine( host_of       => sub { return undef } );

    # Public, because a reserved TLD has only ever one candidate and so no tie.
    my %common = ( domain => 'tie.example.net', install_dir => '/opt/domains', admin_user => 'someadmin' );

    like(
        exception { fresh('lexicon')->validate(%common) },
        qr/dns_preference/,
        'with nobody to settle it, the tie is refused rather than guessed at'
    );

    # A fresh recipe per case: validated() memoises onto the object.
    my %by_local = fresh('lexicon')->validate( %common, dns_preference => 'pdns' );
    is( $by_local{lexicon}{type}, 'powerdns', 'and naming the local server here settles it' );

    my %by_registrar = fresh('lexicon')->validate( %common, dns_preference => 'registrar' );
    is( $by_registrar{lexicon}{type}, 'easydns', 'as does naming the registrar' );
};

subtest 'the CA depends on the capability, not on a recipe name' => sub {
    my %common = ( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'someadmin' );

    my %required = fresh('acmeca')->required_recipes(%common);
    my $local    = Provisioner::DNSRecipe->local_implementation;
    ok( exists $required{$local}, "the CA requires whatever runs the DNS on the guest ($local)" );

    my %handed = $required{$local} ? $required{$local}->() : ( sentinel => 1 );
    is_deeply( \%handed, {}, 'and hands it nothing, since its key is the operator to supply' );

    # Following the interface rather than a literal, which is the whole of #149.
    # Asserting the key is 'pdns' would pass just as well against the hardcoded
    # string it replaced, so this moves the answer and checks the CA moved with
    # it.
    # The variable and not the method, because provider_for reads it too.
    local $Provisioner::DNSRecipe::LOCAL_IMPLEMENTATION = 'registrar';

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
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'a.example.net', configured => $nothing ) },
        qr/no[ ]DNS[ ]provider/,
        'and a public one with nothing configured is refused rather than guessed at'
    );

    is( Provisioner::DNSRecipe->implementation_for( domain => 'a.example.net', configured => $registrar ), 'registrar', 'the one that is configured serves it' );

    like(
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'a.test', configured => $registrar, dns_preference => 'registrar' ) },
        qr/reserve/,
        'while naming a registrar for a reserved name is refused'
    );

    like(
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'a.example.net', configured => $both ) },
        qr/dns_preference/,
        'a guest that could answer either way is asked which'
    );

    foreach my $named (qw{pdns registrar}) {
        is( Provisioner::DNSRecipe->implementation_for( domain => 'a.example.net', configured => $both, dns_preference => $named ), $named, "naming $named settles it" );
    }

    # The base class requires the interface for every recipe that serves a
    # name, and states no preference, so the one the domain states elsewhere
    # settles it.
    my $stated = { %$both, letsencrypt => { dns_preference => 'registrar' } };
    is( Provisioner::DNSRecipe->implementation_for( domain => 'a.example.net', configured => $stated ), 'registrar', 'a requirer that states none gets the one another recipe of the domain states' );
    like(
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'a.example.net', configured => { %$stated, lexicon => { dns_preference => 'pdns' } } ) },
        qr/states[ ]dns_preference[ ]as[ ]each[ ]of[ ]pdns[ ]registrar/,
        'and two recipes that state different ones are refused'
    );

    # A domain layered onto another is served by what that guest runs, so the
    # host's configuration counts as well as its own.
    is(
        Provisioner::DNSRecipe->implementation_for( domain => 'tenant.example.net', configured => $nothing, host_configured => $registrar ),
        'registrar',
        'and a tenant is served by what its host holds'
    );

    # The machine's name, so a refusal says which guest was looked at rather
    # than naming the domain that was never going to have a server of its own.
    like(
        exception {
            Provisioner::DNSRecipe->implementation_for(
                domain         => 'tenant.example.net',
                configured     => $nothing,
                host           => 'host.example.net',
                dns_preference => 'pdns',
            );
        },
        qr/host\.example\.net[ ]is[ ]configured[ ]with[ ]no[ ]pdns/,
        'and a refusal names the machine it asked about, not the domain on it'
    );

    like(
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'a.example.net' ) },
        qr/was[ ]not[ ]told[ ]what/,
        'asked without a configuration at all, it says so rather than resolving against something else'
    );
};

subtest 'a domain that names an authority goes to the registrar, which reaches that guest' => sub {
    my $nothing = { registrar => { authority => 'ns.test' } };
    my $local   = { pdns => {}, registrar => { authority => 'ns.test' } };

    is( Provisioner::DNSRecipe->implementation_for( domain => 'web.lab.example.net', configured => { registrar => { authority => 'ns.example.net' } } ), 'registrar', 'with no type configured' );
    is( Provisioner::DNSRecipe->implementation_for( domain => 'web.lab.test',        configured => $nothing ),                                           'registrar', 'and under a reserved TLD, where the authority holds the zone' );
    is( Provisioner::DNSRecipe->implementation_for( domain => 'web.lab.test', configured => $nothing, dns_preference => 'registrar' ), 'registrar', 'where it may also be named' );

    like(
        exception { Provisioner::DNSRecipe->implementation_for( domain => 'web.lab.test', configured => $local ) },
        qr/both/,
        'a guest that also runs a pdns of its own has a tie to settle'
    );

    is( Provisioner::DNSRecipe->implementation_for( domain => 'ns.test', configured => $local ), 'pdns', 'a guest that names itself is not its own authority' );
    is( Provisioner::DNSRecipe->implementation_for( domain => 'tenant.test', configured => {}, host => 'ns.test', host_configured => $local ), 'pdns', 'nor is a domain on that guest' );
};

subtest 'the interface names the key that settles a tie' => sub {

    # bin/new_config reads this out of the configuration of whichever recipe
    # declared the dependency, so it can resolve one without knowing what DNS is.
    is( Provisioner::DNSRecipe->tiebreaker_key, 'dns_preference', 'which is where operators already write it' );

    my %schema = Provisioner::Cookbook->load('letsencrypt')->args();
    ok( exists $schema{properties}{ Provisioner::DNSRecipe->tiebreaker_key }, 'and the recipe that takes it declares it' );
};

subtest 'credentials_for tells a missing provider from a broken one' => sub {
    my $dns = Test::MockModule->new('Provisioner::DNSRecipe');
    $dns->redefine( provider_for => sub { return 'nosuchprovider' } );

    like(
        exception { Provisioner::DNSRecipe->credentials_for( domain => 'a.test' ) },
        qr/nosuchprovider[ ]is[ ]not[ ]a[ ]recipe/,
        'a provider with no recipe is named as missing'
    );

    # A recipe that exists but does not compile has to show its own error.
    # Reporting it as missing sends the operator to look for a file that is there.
    $dns->redefine( provider_for => sub { return 'broken' } );
    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( has  => sub { return 1 } );
    $cookbook->redefine( load => sub { die "syntax error at broken.pm line 3\n" } );

    like(
        exception { Provisioner::DNSRecipe->credentials_for( domain => 'a.test' ) },
        qr/syntax[ ]error[ ]at[ ]broken[.]pm/,
        'a provider whose recipe does not load shows why it did not'
    );
};

subtest 'each implementation takes the names it is handed without declaring them' => sub {
    my @implementations = Provisioner::Cookbook->implementations('Provisioner::DNSRecipe');
    ok( scalar @implementations, 'Provisioner::DNSRecipe has implementations to ask' );
    foreach my $recipe ( @implementations, 'letsencrypt' ) {
        my %schema = Provisioner::Cookbook->load($recipe)->schema;
        is( $schema{properties}{hostnames}{type}, 'array', "$recipe has the hostnames option" );
    }

    # The schema refuses a key that nothing declares, so a recipe that
    # is handed no names must not declare them.
    my %nginx = Provisioner::Cookbook->load('nginx')->schema;
    ok( !exists $nginx{properties}{hostnames}, 'and a recipe that is handed none does not' );
};

# What a DNS recipe publishes.  The configuration is mocked, because whether a
# recipe publishes depends on which recipe provider_for says holds the zone.
# A registrar cannot hold a zone under a reserved TLD, so its cases are under
# example.net.
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

subtest 'the recipe that holds the zone publishes the records of the domain' => sub {
    my ( $opts, $fragment ) = publishing( 'registrar', $REGISTRAR, %ON_PUBLIC );

    is( $opts->{publish_records}, 1, 'a registrar that holds the zone publishes' );
    my $queued = qr/queue_postrun_task[ ]\S+publish_dns_records[ ]/;
    like( $fragment, qr/${queued}\Q$PUBLIC\E[ ]192[.]0[.]2[.]50[ ]/, 'in the postrun, with the address the guest was built with' );
    like( $fragment, qr/[ ]alt[.]\Q$PUBLIC\E[ ]www[.]\Q$PUBLIC\E$/m, 'and each name: the configured aliases and the names that recipes handed over, sorted' );

    my ($pdns) = publishing( 'pdns', { pdns => { api_key => 'k' } }, domain => $DOMAIN, main_ip => '192.0.2.51', data_source => '/bogus' );
    is( $pdns->{publish_records}, 1, 'and so does a pdns that serves its own zone, which corrects its records on a rebuild' );
};

subtest 'a recipe that does not hold the zone publishes nothing' => sub {
    my ( $opts, $fragment ) = publishing( 'registrar', { %$REGISTRAR, pdns => { api_key => 'k' }, letsencrypt => { dns_preference => 'pdns' } }, %ON_PUBLIC );
    is( $opts->{publish_records}, 0, 'a registrar on a guest whose own pdns holds the zone' );
    unlike( $fragment, qr/\S/, 'and its fragment is empty' );

    my ($reserved) = publishing( 'registrar', $REGISTRAR, %ON_PUBLIC, domain => $DOMAIN, aliases => {}, hostnames => [] );
    is( $reserved->{publish_records}, 0, 'nor one for a name under a reserved TLD, which only the guest can serve' );
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
