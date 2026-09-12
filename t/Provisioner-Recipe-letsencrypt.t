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
use File::Temp  qw{tempdir};
use File::Slurper();

use FindBin::libs;

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
        registrar    => { type => 'easydns', user => 'somebody', key => 'a-token' },
        %extra,
    );

    return ( $recipe, $dir, sub { File::Slurper::read_text("$dir/$_[0]") } );
}

# What prefer_local_dns needs beside itself: the token, and a pdns to talk to.
my %LOCAL = ( prefer_local_dns => 1, local_dns_access_token => 'an-api-key' );

subtest 'the CA defaults to the public one where a public CA could issue' => sub {
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
    is( $handed{api_key}, $opts{local_dns_access_token}, 'and the hook is given the same one' );

    # The token reaching the file dehydrated executes, which is the thing that
    # actually failed: every other consumer had it and agreed, while the hook
    # rendered no export, because new_config supplies an empty token before the
    # depsolver has added the pdns this recipe asks for.
    my $hook = $slurp->('domain.hook');
    like( $hook, qr/^export LEXICON_POWERDNS_AUTH_TOKEN="[0-9a-f]{64}"$/m, 'and the hook exports it, rather than omitting an empty one' );
};

subtest 'a reserved TLD with no dns server of its own is left to the public CA' => sub {
    my ( undef, undef, $slurp ) = generated( modules => ['letsencrypt'] );

    # enrich turns on prefer_local_dns for the fleet CA, and the guard below it
    # dies without a dns provider -- so routing every .test domain at our own CA
    # made a bare render of this recipe fatal, which is t/recipes.t and
    # bin/recipes both.  Nothing can issue for the name either way; this leaves
    # the failure where it already was instead of making a new one here.
    my $default = $Provisioner::Recipe::letsencrypt::DEFAULT_CA;
    like( $slurp->('dehydrated.conf'), qr/^\QCA="$default"\E$/m, 'rather than dying on a mode it cannot complete' );
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
    my ( undef, undef, $slurp ) = generated(%LOCAL);
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
    my ( undef, undef, $slurp ) = generated(%LOCAL);
    my $fetcher = $slurp->('get_cert');

    # The postrun queue is in fragment order and this recipe's fragment runs
    # before pdns's, so the restarts that put the API socket and the zone in
    # place are queued behind the fetcher.  Measured on a guest: lexicon found
    # no socket, so the af-unix patch left the endpoint unmangled and requests
    # refused it, and --resolve-zone-name resolved to nothing.
    ok( index( $fetcher, '/var/spool/powerdns/api.sock' ) >= 0, 'it waits for the socket lexicon talks to' );
    ok( index( $fetcher, 'SOA' ) >= 0,                          'and for the zone to be answered' );

    ( undef, undef, $slurp ) = generated( domain => $PUBLIC );
    ok( index( $slurp->('get_cert'), '/var/spool/powerdns/api.sock' ) < 0, 'and waits for nothing where the DNS is somebody else' );
};

subtest 'prefer_local_dns without a DNS server is refused' => sub {
    my $recipe = Provisioner::Cookbook->load( 'letsencrypt', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );

    like(
        exception { $recipe->enrich( %LOCAL, domain => $DOMAIN, modules => ['letsencrypt'] ) },
        qr/dns provider/i,
        'rather than writing a challenge nothing can serve'
    );
};

Test::NoWarnings::had_no_warnings();

done_testing;
