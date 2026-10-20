#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-letsencrypt.t - which CA a domain asks, and how the
challenge reaches the server that answers for it

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use Test::MockModule();
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();

use FindBin::libs;

# Never this machine's real configuration.  The recipe asks
# Provisioner::Cookbook which guest holds a domain and what it is configured
# with, so a fleet that happened to name one of the domains below would change
# what this file asserts.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();
use Provisioner::Recipe::letsencrypt();

# These patterns quotemeta a literal on purpose: a fixture string this test
# wrote itself, full of dots and slashes that would otherwise need escaping one
# at a time.  The policy is about production code, where a \Q...\E round
# anything but an interpolated value is usually an accident.
## no critic (RegularExpressions::PreventUselessMetacharacterEscapes)

my $DOMAIN = 'letsencrypt.test.test';

# A name a public CA could actually issue for.  .test, .example, .invalid and
# .localhost are all reserved, and reserved is precisely the case that routes
# away from the public CA -- so the public path cannot be tested under one.
my $PUBLIC = 'letsencrypt.example.net';

sub generated {
    my (%extra) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'letsencrypt', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    $recipe->generate_files(
        $dir,
        domain      => $DOMAIN,
        install_dir => '/opt/domains',
        script_dir  => '/root/bin',
        admin_user  => 'someadmin',
        main_ip     => '192.0.2.9',
        hostnames   => ["www.$DOMAIN"],
        modules     => [qw{pdns letsencrypt}],
        %extra,
    );

    return ( $recipe, $dir, sub { File::Slurper::read_text("$dir/$_[0]") } );
}

# "This domain is served by a registrar", said the way the configuration says
# it.  The credentials are the registrar recipe's own block now, so a test
# configures that recipe rather than handing letsencrypt a hash -- which is also
# what stops the recipe from having an argument and a recipe under one name.
#
# Returns the guard: Test::MockModule unmocks when it goes out of scope, so keep
# it in a lexical for as long as the domain should look configured.
sub with_registrar {
    my (%extra) = @_;

    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine(
        domain_config => sub {
            return { registrar => { type => 'easydns', user => 'somebody', key => 'a-token' }, letsencrypt => {}, %extra };
        }
    );

    return $mock;
}

subtest 'the CA defaults to the public one where a public CA could issue' => sub {
    my $registrar = with_registrar();
    my ( undef, undef, $slurp ) = generated( domain => $PUBLIC );

    # Read off the module: a literal here would pass while saying nothing about
    # what the recipe actually defaults to.
    my $default = $Provisioner::Recipe::letsencrypt::DEFAULT_CA;
    like( $slurp->('dehydrated.conf'),   qr/^\QCA="$default"\E$/m, "the guest-wide config names it ($default)" );
    like( $slurp->('dehydrated.domain'), qr/^\QCA="$default"\E$/m, 'and so does the per-domain one' );
};

subtest 'a reserved TLD asks the fleet own CA, since no public one can issue' => sub {
    my ( $recipe, undef, $slurp ) = generated();

    # Let's Encrypt answers a request for a .test name with rejectedIdentifier,
    # "Domain name does not end with a valid public suffix (TLD)" -- measured on
    # a guest, where it ended every .test provision with a red makefile.
    like( $slurp->('dehydrated.conf'), qr{^CA="https://localhost:\d+/acme/trog/directory"$}m, 'the guest-wide config asks our own' );

    my %required = $recipe->required_recipes( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'someadmin' );
    ok( exists $required{acmeca},    'the CA that serves it is required' );
    ok( exists $required{registrar}, 'and so is the registrar, which says what answers its challenge' );

    # pdns authenticates lexicon with this, and the hook presents it.  Two
    # different values is a challenge that cannot be written, so they are pinned
    # against each other rather than each against a literal.
    # validate() ends by calling enrich, so this is the real path: calling both
    # ran enrich twice, and the second pass saw ca already set, skipped the
    # branch under test and asserted nothing about it.
    my %opts   = $recipe->validate( domain => $DOMAIN, modules => [qw{pdns letsencrypt}], install_dir => '/opt/domains', admin_user => 'someadmin' );
    my %server = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' )->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => tempdir( CLEANUP => 1 ), distro => 'ubuntu' )->validate( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'someadmin' );
    ok( length $server{api_key}, 'pdns makes an api key' );
    is( $server{api_key}, $opts{lexicon}{key}, 'and the hook is given the same one' );

    # The token reaching the file dehydrated executes, which is the thing that
    # actually failed: every other consumer had it and agreed, while the hook
    # rendered no export, because new_config supplies an empty token before the
    # depsolver has added the pdns this recipe asks for.
    my $hook = $slurp->('domain.hook');
    like( $hook, qr/^export[ ]LEXICON_POWERDNS_AUTH_TOKEN="[\da-f]{64}"$/m, 'and the hook exports it, rather than omitting an empty one' );
};

subtest 'the services that read the certificate are those that the recipes on the guest name' => sub {
    my %domain_conf = ( ldap => {}, plexmediaserver => {}, nginx => {}, mail => {} );
    Provisioner::Cookbook->resolve_dependencies(
        modules       => [qw{ldap plexmediaserver nginx mail}],
        domain_conf   => \%domain_conf,
        global_config => { domain => $DOMAIN, install_dir => '/opt/domains', script_dir => '/root/bin', admin_user => 'someadmin' },
        distro        => 'ubuntu',
        provisioner   => { template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => tempdir( CLEANUP => 1 ), distro => 'ubuntu', target_packager => 'deb' },
        domain        => $DOMAIN,
    );
    is_deeply( [ sort @{ $domain_conf{letsencrypt}{certificate_readers} // [] } ], [qw{dovecot nginx plexmediaserver postfix slapd}], 'each recipe that serves the certificate hands its units to letsencrypt' );

    my ($recipe) = generated();
    my %opts = $recipe->validate( domain => $DOMAIN, modules => ['letsencrypt'], install_dir => '/opt/domains', admin_user => 'someadmin', certificate_readers => [qw{nginx postfix nginx}] );
    is_deeply( $opts{certificate_readers}, [qw{nginx postfix}], 'and letsencrypt reloads each unit once' );
};

subtest 'a reserved TLD is served locally whatever reached the module list' => sub {
    my ( undef, undef, $slurp ) = generated( modules => ['letsencrypt'] );

    # The module list is not what decides this.  The depsolver adds the pdns
    # that the registrar pulls in between required_recipes and enrich, so the
    # two would get different answers from it.
    like( $slurp->('dehydrated.conf'), qr{^CA="https://localhost:\d+/acme/trog/directory"$}m, 'the fleet CA, with pdns absent from the list' );

    my %opts = fresh()->validate( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'someadmin', modules => ['letsencrypt'] );
    is( $opts{lexicon}{type}, 'powerdns', 'and lexicon writes the challenge into the server on the guest' );
};

subtest 'a domain can name one of the fleet own instead' => sub {
    my $url = 'https://localhost:9000/acme/trog/directory';
    my ( $recipe, undef, $slurp ) = generated( ca => $url );

    like( $slurp->('dehydrated.conf'),   qr/^\QCA="$url"\E$/m, 'the guest-wide config asks it' );
    like( $slurp->('dehydrated.domain'), qr/^\QCA="$url"\E$/m, 'and the per-domain one' );

    # The edge is what orders the CA ahead of the fetcher, which runs in the
    # postrun: without it the fetcher can be asking something not yet started.
    my %required = $recipe->required_recipes( domain => $DOMAIN, ca => $url, install_dir => '/opt/domains', admin_user => 'someadmin' );
    ok( exists $required{acmeca}, 'and the recipe that serves it is required' );

    %required = $recipe->required_recipes( domain => $PUBLIC, install_dir => '/opt/domains', admin_user => 'someadmin' );
    ok( !exists $required{acmeca}, 'while a name the public CA can issue for needs nothing of ours' );
};

subtest 'the local DNS path asks lexicon to resolve the zone' => sub {
    my ( undef, undef, $slurp ) = generated();
    my $hook = $slurp->('domain.hook');

    # lexicon reduces a domain to its registrable name before asking for a zone,
    # and a reserved TLD is not a public suffix -- so <guest>.test collapsed to
    # the zone "test", and DELEGATED was composed back onto that, asking for
    # zones/<guest>.test.test.  Every challenge 404'd, on every guest.
    my @calls = grep { m/^\s+lexicon\s/ } split( m/\n/, $hook );
    is( scalar @calls, 2, 'the hook deploys a record and cleans it up' );
    like( $_, qr/--resolve-zone-name/, 'and asks lexicon to find the zone itself' ) for @calls;

    like( $hook, qr{LEXICON_POWERDNS_PDNS_SERVER="/var/spool/powerdns/api\.sock"}, 'and the socket is named for the provider' );
};

subtest 'a registrar is left alone' => sub {
    my $registrar = with_registrar();
    my ( undef, undef, $slurp ) = generated( domain => $PUBLIC );
    my $hook = $slurp->('domain.hook');

    # The flag costs live DNS queries to work out a zone the registrar path
    # already knows: there the domain is the zone, and tldextract is right.
    ok( index( $hook, '--resolve-zone-name' ) < 0, 'no zone resolution where the domain is the zone' );
    like( $hook, qr/LEXICON_EASYDNS_AUTH_TOKEN/, 'and the registrar credentials are still exported' );
};

subtest 'the ACME account comes back for a public CA, and not for one of ours' => sub {
    my ($recipe) = generated();
    my %common = ( install_dir => '/opt/domains', admin_user => 'someadmin' );

    my %public = $recipe->restores( %common, domain => $PUBLIC );
    ok( exists $public{'/etc/dehydrated/accounts'}, 'a public CA outlives the guest, so its account is worth keeping' );

    # acmeca is rebuilt with the guest, on an empty database: a restored account
    # is an identity it has never heard of, and the order comes back
    # accountDoesNotExist.  Measured on a rebuilt guest.
    my %ours = $recipe->restores( %common, domain => $DOMAIN );
    ok( !exists $ours{'/etc/dehydrated/accounts'},         'ours does not, so the account is left behind' );
    ok( exists $ours{"/var/lib/dehydrated/certs/$DOMAIN"}, 'while the certificates still come back' );

    # A third party that is not Let's Encrypt is still a third party: the account
    # is this installation's identity with them, re-registering each rebuild
    # spends it, and with Let's Encrypt itself it breaches their terms.  Only a
    # CA on this guest's own loopback is rebuilt with the guest.
    foreach my $elsewhere ( 'https://acme.zerossl.com/v2/DV90', 'buypass', $Provisioner::Recipe::letsencrypt::DEFAULT_CA ) {
        my %named = $recipe->restores( %common, domain => $PUBLIC, ca => $elsewhere );
        ok( exists $named{'/etc/dehydrated/accounts'}, "an account with $elsewhere is kept" );
    }

    my %local = $recipe->restores( %common, domain => $PUBLIC, ca => 'https://localhost:9000/acme/trog/directory' );
    ok( !exists $local{'/etc/dehydrated/accounts'}, 'while one on our own loopback is not' );
};

subtest 'the fetcher registers before it asks for anything' => sub {
    my ( undef, undef, $slurp ) = generated( ca => 'https://localhost:9000/acme/trog/directory' );
    my $fetcher = $slurp->('get_cert');

    # The global fragment registers too, but global targets run before any
    # recipe's -- so on a guest whose CA is one of its own recipes, that happened
    # while nothing was listening, and --cron will not run for an account that
    # was never made.
    # The commands, not the whole file: the comment above them names both flags,
    # so a raw index() finds the prose rather than the line that runs.
    my @lines      = split( m/\n/, $fetcher );
    my ($register) = grep { $lines[$_] =~ m/\Adehydrated\b\N*--register/ } 0 .. $#lines;
    my ($cron)     = grep { $lines[$_] =~ m/\Adehydrated\b\N*--cron/ } 0 .. $#lines;

    ok( defined $register,                  'the fetcher registers' );
    ok( defined $cron && $register < $cron, 'and does it before asking for a certificate' )
      or diag "register on line $register, cron on line $cron";
};

subtest 'the fetcher waits for the server that answers its challenge' => sub {
    my ( undef, undef, $slurp ) = generated();
    my $fetcher = $slurp->('get_cert');

    # The postrun queue is in fragment order and this recipe's fragment runs
    # before pdns's, so the restarts that put the API socket and the zone in
    # place are queued behind the fetcher.  Measured on a guest: lexicon found
    # no socket, so the af-unix patch left the endpoint unmangled and requests
    # refused it, and --resolve-zone-name resolved to nothing.
    ok( index( $fetcher, '/var/spool/powerdns/api.sock' ) >= 0, 'it waits for the socket lexicon talks to' );
    ok( index( $fetcher, 'SOA' ) >= 0,                          'and for the zone to be answered' );

    # Two SOA lookups, and the difference between them is the whole finding.
    # @127.0.0.1 asks the server; the bare one asks the resolver lexicon walks
    # the zone with for --resolve-zone-name, and that step-ca validates through.
    # On a guest the first passed while systemd's stub knew nothing of the zone,
    # so the wait fell through and every challenge failed on zones/.
    my @soa = grep { m/\bdig[ ]\+short\b/ } split( m/\n/, $fetcher );
    is( scalar @soa, 2, 'it waits on the server and on the resolver separately' );
    ok( ( scalar grep { index( $_, '@127.0.0.1' ) >= 0 } @soa ), 'one asks the server directly' );
    ok( ( scalar grep { index( $_, '@' ) < 0 } @soa ),           'and one asks whatever the guest resolves with' );

    {
        my $registrar = with_registrar();
        ( undef, undef, $slurp ) = generated( domain => $PUBLIC );
        ok( index( $slurp->('get_cert'), '/var/spool/powerdns/api.sock' ) < 0, 'and waits for nothing where the DNS is somebody else' );
    }
};

subtest 'a domain sharing a machine asks pdns with that machine key' => sub {
    my %common = ( install_dir => '/opt/domains', admin_user => 'someadmin', modules => [qw{pdns letsencrypt}] );

    # The arrangement said the way an operator says it, in _shared, rather than
    # handed to the recipe as an argument.  Which guest holds a domain is the
    # configuration's to answer -- Provisioner::Cookbook/host_of -- and a test
    # that passes the answer in cannot tell whether the recipe ever asked.
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", <<'YAML' );
_shared:
    first.test:
        - second.test
first.test:
    pdns:
    letsencrypt:
second.test:
    letsencrypt:
third.test:
    pdns:
    letsencrypt:
YAML
    Provisioner::Cookbook->forget();

    # One pdns serves the whole guest, and its global target is made once -- so a
    # domain layered onto another never rewrites api.conf and the key in it stays
    # the first domain's.  A token of its own is one the server does not know:
    # measured on a shared host, where every challenge came back 401.
    my %host   = fresh()->validate( %common, domain => 'first.test' );
    my %tenant = fresh()->validate( %common, domain => 'second.test' );
    my %alone  = fresh()->validate( %common, domain => 'third.test' );

    # Length first, and not merely equality: two empty strings are equal, so an
    # absent credential would satisfy the comparison below while rendering a
    # hook that authenticates with nothing.
    ok( length( $host{lexicon}{key} // q{} ) >= 32, 'the machine has a token' );
    is( $tenant{lexicon}{key}, $host{lexicon}{key}, 'a domain on it presents that one' );
    isnt( $alone{lexicon}{key}, $host{lexicon}{key}, 'while a domain with a machine of its own gets its own' );

    # The hook is only half of it.  The server configures itself with its own
    # key, and a hook that presents another gets a 401.
    my $pdns = Provisioner::Cookbook->load('pdns');
    is( $pdns->api_key_for('second.test'), $host{lexicon}{key}, 'and the server of the machine expects that key' );

    Provisioner::Cookbook->forget();
};

sub fresh {
    return Provisioner::Cookbook->load( 'letsencrypt', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

subtest 'a guest that names an authority leaves its challenge to the authority' => sub {
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine( domain_config => sub { return { registrar => { type => 'pdns', authority => 'ns.test.test' }, letsencrypt => {} } } );

    # Measured on a scratch guest: a pdns of its own made its recursor answer
    # for its zone, nostubresolver bypassed the route to the authority, and the
    # name of the API of the authority did not resolve.
    my %required = fresh()->required_recipes( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'someadmin' );
    ok( !exists $required{acmeca}, 'the CA of the authority issues, so the guest runs none of its own' );
    ok( !exists $required{pdns},   'and the guest gets no DNS server of its own from it' );

    my %opts = fresh()->validate( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'someadmin' );
    is( $opts{ca},                'https://dnsapi.ns.test.test/acme/trog/directory', 'dehydrated asks the CA of the authority, through its API' );
    is( $opts{lexicon}{key_file}, '/etc/lexicon/' . $DOMAIN . '.token',              'and lexicon writes the challenge with the token that the authority issued' );

    # Measured on the same guest: the stub of systemd-resolved answered a name
    # with no record with the SOA of the root, so lexicon asked for the zone "."
    # for www and the authority refused it.
    my ( undef, undef, $slurp ) = generated();
    my $hook      = $slurp->('domain.hook');
    my $challenge = qr/--name="_acme-challenge[.]\$\{DOMAIN\}[.]"/;
    like( $hook, qr/^\s*lexicon[ ].*[ ]create[ ]\Q$DOMAIN\E[ ]TXT[ ]$challenge/m, 'the hook writes each challenge into the zone of the guest' );
    like( $hook, qr/^\s*lexicon[ ].*[ ]delete[ ]\Q$DOMAIN\E[ ]TXT[ ]/m,           'and removes it from there' );

    # lexicon reaches the authority at a URL, and a URL is never a socket, so a
    # wait for one ran out its two minutes on every build.
    unlike( $slurp->('get_cert'), qr/\[[ ]-S[ ]/, 'and the fetcher waits for no socket of its own' );
};

subtest 'the CA of an authority issues only where its constraint permits the name' => sub {
    my %authority_of = ( $DOMAIN => 'ns.example.net', 'chained.test.test' => 'mid.test.test', 'mid.test.test' => 'top.test.test' );
    my $mock         = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine(
        domain_config => sub {
            my ( undef, $domain ) = @_;
            return { pdns => {}, ( $authority_of{$domain} ? ( registrar => { authority => $authority_of{$domain} } ) : () ) };
        }
    );
    $mock->redefine( host_of => sub { return } );

    my $acmeca = Provisioner::Cookbook->load('acmeca');
    is( $acmeca->fleet_ca_of($DOMAIN), undef, 'an authority under another TLD has no CA for the name' );
    my %required = fresh()->required_recipes( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'someadmin' );
    ok( exists $required{acmeca}, 'so the guest runs its own' );
    is( $acmeca->directory_for($DOMAIN), 'https://localhost:9000/acme/trog/directory', 'and asks it on loopback' );

    # An authority that names an authority of its own runs no CA.
    is( $acmeca->fleet_ca_of('chained.test.test'), 'top.test.test', 'a chain of authorities ends at the one that runs a CA' );
};

subtest 'without a zone it is told, lexicon finds the zone of each name' => sub {
    my $registrar = with_registrar();
    my ( undef, undef, $slurp ) = generated( domain => $PUBLIC );
    like( $slurp->('domain.hook'), qr/[ ]create[ ]\$\{DOMAIN\}[ ]TXT[ ]/, 'so an alias in another zone of the registrar is written there' );
};

subtest 'a provider that could not answer the challenge is refused' => sub {
    my $public = sub { return ( domain => $PUBLIC, install_dir => '/opt/domains', admin_user => 'someadmin', @_ ); };

    like(
        exception { fresh()->enrich( $public->( prefer_local_dns => 1 ) ) },
        qr/registrar[ ]recipe/,
        'the flag that this replaced names what replaced it, rather than being ignored'
    );

    # Configured with neither, said explicitly rather than by picking a domain
    # the installation happens not to configure.
    my $nothing = Test::MockModule->new('Provisioner::Cookbook');
    $nothing->redefine( domain_config => sub { return {} } );

    like(
        exception { fresh()->enrich( $public->() ) },
        qr/no[ ]server[ ]of[ ]this[ ]installation[ ]holds[ ]its[ ]zone/,
        'a domain with neither is told so, rather than rendering a hook that cannot run'
    );
};

subtest 'a public guest that holds its own zone answers its own challenge' => sub {

    # A public name whose zone this fleet serves: the registrar of _base is
    # there too, and the server on the guest holds the zone.
    my $registrar = with_registrar( pdns => { api_key => 'a-key' }, registrar => { type => 'easydns', key => 'a-token', authority => $PUBLIC } );

    my %opts = fresh()->enrich( domain => $PUBLIC, install_dir => '/opt/domains', admin_user => 'someadmin' );
    is( $opts{lexicon}{type}, 'powerdns', 'the local server is what lexicon is given' );
    is( $opts{lexicon}{key},  'a-key',    'with the key that the operator set for it' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
