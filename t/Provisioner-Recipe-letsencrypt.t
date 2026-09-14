#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

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
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();
use Provisioner::Recipe::letsencrypt();

my $DOMAIN = 'letsencrypt.test.test';

# A name a public CA could actually issue for.  .test, .example, .invalid and
# .localhost are all reserved, and reserved is precisely the case that routes
# away from the public CA -- so the public path cannot be tested under one.
my $PUBLIC = 'letsencrypt.troglodyne.net';

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
        domain       => $DOMAIN,
        install_dir  => '/opt/domains',
        script_dir   => '/root/bin',
        admin_user   => 'doge',
        main_ip      => '192.168.1.9',
        full_aliases => ["www.$DOMAIN"],
        modules      => [qw{pdns letsencrypt}],
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

# The local DNS path needs nothing named at all now: a reserved TLD has only the
# one provider that could serve it, the recipe resolves that for itself, and the
# credential belongs to pdns rather than being handed over.

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

    my %required = $recipe->required_recipes( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'doge' );
    ok( exists $required{acmeca}, 'the CA that serves it is required' );
    ok( exists $required{pdns},   'and so is the dns server that answers its challenge' );

    # pdns authenticates lexicon with this, and the hook presents it.  Two
    # different values is a challenge that cannot be written, so they are pinned
    # against each other rather than each against a literal.
    # validate() ends by calling enrich, so this is the real path: calling both
    # ran enrich twice, and the second pass saw ca already set, skipped the
    # branch under test and asserted nothing about it.
    my %handed = $required{pdns}->();
    my %opts   = $recipe->validate( domain => $DOMAIN, modules => [qw{pdns letsencrypt}], install_dir => '/opt/domains', admin_user => 'doge' );
    ok( length $handed{api_key}, 'pdns is handed an api key' );
    is( $handed{api_key}, $opts{registrar}{key}, 'and the hook is given the same one' );

    # The token reaching the file dehydrated executes, which is the thing that
    # actually failed: every other consumer had it and agreed, while the hook
    # rendered no export, because new_config supplies an empty token before the
    # depsolver has added the pdns this recipe asks for.
    my $hook = $slurp->('domain.hook');
    like( $hook, qr/^export LEXICON_POWERDNS_AUTH_TOKEN="[0-9a-f]{64}"$/m, 'and the hook exports it, rather than omitting an empty one' );
};

subtest 'a reserved TLD is served locally whatever reached the module list' => sub {
    my ( undef, undef, $slurp ) = generated( modules => ['letsencrypt'] );

    # The module list is not what decides this, and asking it is what made the
    # two callers disagree: the depsolver adds the pdns this recipe pulls in
    # through acmeca between required_recipes and enrich, so the same domain
    # resolved as the registrar for the first and as the local server for the
    # second.  A reserved TLD is served locally because this recipe requires
    # what serves it, which is true before the depsolver has run.
    like( $slurp->('dehydrated.conf'), qr{^CA="https://localhost:\d+/acme/trog/directory"$}m, 'the fleet CA, with pdns absent from the list' );

    my %required = _fresh()->required_recipes( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'doge', modules => ['letsencrypt'] );
    ok( exists $required{pdns}, 'because the recipe is what puts that server there' );

    my %opts = _fresh()->validate( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'doge', modules => ['letsencrypt'] );
    is( $opts{dns_preference}, 'pdns', 'and both callers resolve the one provider' );
};

subtest 'a domain can name one of the fleet own instead' => sub {
    my $url = 'https://localhost:9000/acme/trog/directory';
    my ( $recipe, undef, $slurp ) = generated( ca => $url );

    like( $slurp->('dehydrated.conf'),   qr/^\QCA="$url"\E$/m, 'the guest-wide config asks it' );
    like( $slurp->('dehydrated.domain'), qr/^\QCA="$url"\E$/m, 'and the per-domain one' );

    # The edge is what orders the CA ahead of the fetcher, which runs in the
    # postrun: without it the fetcher can be asking something not yet started.
    my %required = $recipe->required_recipes( domain => $DOMAIN, ca => $url, install_dir => '/opt/domains', admin_user => 'doge' );
    ok( exists $required{acmeca}, 'and the recipe that serves it is required' );

    %required = $recipe->required_recipes( domain => $PUBLIC, install_dir => '/opt/domains', admin_user => 'doge' );
    ok( !exists $required{acmeca}, 'while a name the public CA can issue for needs nothing of ours' );
};

subtest 'the local DNS path asks lexicon to resolve the zone' => sub {
    my ( undef, undef, $slurp ) = generated();
    my $hook = $slurp->('domain.hook');

    # lexicon reduces a domain to its registrable name before asking for a zone,
    # and a reserved TLD is not a public suffix -- so <guest>.test collapsed to
    # the zone "test", and DELEGATED was composed back onto that, asking for
    # zones/<guest>.test.test.  Every challenge 404'd, on every guest.
    my @calls = grep { m/^\s+lexicon\s/ } split( "\n", $hook );
    is( scalar @calls, 2, 'the hook deploys a record and cleans it up' );
    like( $_, qr/--resolve-zone-name/, 'and asks lexicon to find the zone itself' ) for @calls;

    unlike( $hook, qr/LEXICON_DELEGATED/, 'DELEGATED is not set, which is what composed the wrong name' );
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
    my %common = ( install_dir => '/opt/domains', admin_user => 'doge' );

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
    my @lines      = split( "\n", $fetcher );
    my ($register) = grep { $lines[$_] =~ m/\Adehydrated\b.*--register/ } 0 .. $#lines;
    my ($cron)     = grep { $lines[$_] =~ m/\Adehydrated\b.*--cron/ } 0 .. $#lines;

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
    my @soa = grep { m/\bdig \+short\b/ } split( "\n", $fetcher );
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
    my %common = ( install_dir => '/opt/domains', admin_user => 'doge', modules => [qw{pdns letsencrypt}] );

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
    my %host   = _fresh()->validate( %common, domain => 'first.test' );
    my %tenant = _fresh()->validate( %common, domain => 'second.test' );
    my %alone  = _fresh()->validate( %common, domain => 'third.test' );

    # Length first, and not merely equality: two empty strings are equal, so an
    # absent credential would satisfy the comparison below while rendering a
    # hook that authenticates with nothing.
    ok( length( $host{registrar}{key} // q{} ) >= 32, 'the machine has a token' );
    is( $tenant{registrar}{key}, $host{registrar}{key}, 'a domain on it presents that one' );
    isnt( $alone{registrar}{key}, $host{registrar}{key}, 'while a domain with a machine of its own gets its own' );

    # The hook is only half of it.  required_recipes hands pdns its api_key on a
    # separate path, and fixing the hook alone left the server configured with
    # one key and told to expect another.
    my %host_req    = _fresh()->required_recipes( %common, domain => 'first.test' );
    my %tenant_req  = _fresh()->required_recipes( %common, domain => 'second.test' );
    my %host_pdns   = $host_req{pdns}   ? $host_req{pdns}->()   : ();
    my %tenant_pdns = $tenant_req{pdns} ? $tenant_req{pdns}->() : ();

    ok( length( $host_pdns{api_key} // q{} ), 'pdns is handed a key for the machine' );
    is( $tenant_pdns{api_key}, $host_pdns{api_key}, 'and a domain on it hands pdns that same key' );

    Provisioner::Cookbook->forget();
};

sub _fresh {
    return Provisioner::Cookbook->load( 'letsencrypt', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

subtest 'a guest that answers its own challenge can resolve its own zone' => sub {
    my %required = _fresh()->required_recipes( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'doge' );

    # lexicon walks the zone through the system resolver for --resolve-zone-name,
    # and step-ca validates dns-01 through it too.  Measured on a scratch guest
    # with no nostubresolver: the walk fell to the root, lexicon asked pdns for
    # zones/. and got a 404, and dig @127.0.0.1 answered for the zone the whole
    # time.  A fleet whose _base carries the recipe never sees this.
    ok( exists $required{nostubresolver}, 'the local provider brings a resolver that can see it' );

    # Somebody else holds the zone, so the guest has no need to resolve it here.
    my $registrar = with_registrar();
    my %elsewhere = _fresh()->required_recipes( domain => $PUBLIC, install_dir => '/opt/domains', admin_user => 'doge' );
    ok( !exists $elsewhere{nostubresolver}, 'while a registrar-served name is handed no resolver of ours' );
};

subtest 'a provider that could not answer the challenge is refused' => sub {
    my $public = sub { return ( domain => $PUBLIC, install_dir => '/opt/domains', admin_user => 'doge', @_ ); };

    # The rename is not silent.  An unrecognised key is dropped by the schema
    # rather than rejected, so a configuration left unmigrated would have
    # resolved to the registrar without saying anything -- on the one domain
    # whose zone this fleet is itself serving.
    like(
        exception { _fresh()->enrich( $public->( prefer_local_dns => 1 ) ) },
        qr/dns_preference/,
        'the flag this replaced names its replacement rather than being ignored'
    );

    like(
        exception { _fresh()->enrich( $public->( dns_preference => 'pdns' ) ) },
        qr/no pdns recipe/,
        'asking for a local server where none is configured is refused'
    );

    # No public registrar can hold a zone under a TLD reserved by RFC 2606, so
    # the credentials could never answer for the name however good they are.
    # Configured rather than handed over, or the refusal under test would be the
    # one about credentials in the wrong place instead.
    {
        my $registrar = with_registrar();
        like(
            exception {
                _fresh()->enrich( domain => $DOMAIN, install_dir => '/opt/domains', admin_user => 'doge', dns_preference => 'registrar' );
            },
            qr/reserve/,
            'and so is naming a registrar for a name no registrar can hold'
        );
    }

    # Configured with neither, said explicitly rather than by picking a domain
    # the installation happens not to configure.  It did the latter until
    # _base.registrar started being inherited by every domain on this fleet, at
    # which point this case quietly stopped being the case it names.
    {
        my $nothing = Test::MockModule->new('Provisioner::Cookbook');
        $nothing->redefine( domain_config => sub { return {} } );

        like(
            exception { _fresh()->enrich( $public->() ) },
            qr/no DNS provider/,
            'a domain with neither is told so, rather than rendering a hook that cannot run'
        );
    }
};

subtest 'a guest that could answer either way is asked which' => sub {

    # A public name whose zone this fleet also serves: the registrar holding it
    # and the server on the guest can each write the record, they write it in
    # different places, and choosing for the operator is a guess.
    my $registrar = with_registrar( pdns => { api_key => 'a-key' } );

    my %both = ( domain => $PUBLIC, install_dir => '/opt/domains', admin_user => 'doge' );

    like(
        exception { _fresh()->enrich(%both) },
        qr/dns_preference/,
        'a tie with no tiebreaker is refused rather than resolved'
    );

    foreach my $named (qw{pdns registrar}) {
        my %opts = _fresh()->enrich( %both, dns_preference => $named );
        is( $opts{dns_preference}, $named, "naming $named settles it" );
    }

    # The tiebreaker decides the hook as well as the answer: the local server is
    # reached over a unix socket lexicon has to be pointed at.
    my %local = _fresh()->enrich( %both, dns_preference => 'pdns' );
    is( $local{registrar}{type}, 'powerdns', 'and the local server is what lexicon is given' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
