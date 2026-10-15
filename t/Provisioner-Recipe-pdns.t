#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-pdns.t - the zone this recipe builds: which names in it are
absolute, and which are deliberately not

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal();
use File::Temp qw{tempdir};
use File::Slurper::Temp();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();
use Provisioner::Recipe::pdns();

# These patterns quotemeta a literal on purpose: a fixture domain full of dots
# that would otherwise need escaping one at a time.
## no critic (RegularExpressions::PreventUselessMetacharacterEscapes)

my $DOMAIN = 'zone.test';

# What bin/new_config hands the zone template.  Aliases arrive fully qualified:
# new_config appends www and mail to the domain itself, and whatever a domain
# names in its _global is spelled out in full as well.
my %VARS = (
    domain      => $DOMAIN,
    admin_email => 'someadmin@zone.test',
    ipmap       => { $DOMAIN => '192.0.2.50' },
    aliases     => { $DOMAIN => [ "www.$DOMAIN", "mail.$DOMAIN" ] },
    nameservers => {},
    modules     => [],
    install_dir => '/opt/domains',
    admin_user  => 'someadmin',
);

sub zone {
    my (%over) = @_;

    my $recipe = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );

    return $recipe->render_file( 'files/pdns.zone.tt', %VARS, %over, api_key => 'a-key' );
}

subtest 'a name given in full is emitted absolute' => sub {
    my $zone = zone();

    # The zonefile opens with $ORIGIN <domain>., so a name without a trailing
    # dot has the origin put on it again.  An alias is already the whole name,
    # so relative made www.zone.test answer as www.zone.test.zone.test -- and
    # nothing resolved www.zone.test at all.  Measured on a guest.
    like( $zone, qr/^\Qwww.$DOMAIN\E\.\s+IN\s+CNAME\s+\@/m,  'an alias CNAME ends in a dot' );
    like( $zone, qr/^\Qmail.$DOMAIN\E\.\s+IN\s+CNAME\s+\@/m, 'each of them' );

    # The MX target had the same fault, while every SRV target beside it was
    # already absolute.  Asked of a zone that serves mail, which is the only
    # kind that has an MX to get wrong.
    my $mail = zone( modules => ['mail'] );
    like( $mail, qr/IN\s+MX\s+10\s+\Qmail.$DOMAIN\E\./, 'the MX target ends in a dot' );

    # One assertion for the whole class, so a third instance is caught without
    # anybody having to think of it: nothing in either zone carries the origin
    # twice.
    unlike( $zone, qr/\Q$DOMAIN.$DOMAIN\E/, 'and no name in the zone has the origin on it twice' )
      or diag $zone;
    unlike( $mail, qr/\Q$DOMAIN.$DOMAIN\E/, 'nor in the mail records beside them' )
      or diag $mail;
};

subtest 'a label that belongs to the zone stays relative' => sub {
    my $zone = zone();

    # The opposite mistake.  These are labels rather than names, so a trailing
    # dot would make each of them a name at the root instead.
    like( $zone, qr/^ns1\s+IN\s+A\s/m, 'ns1 is a label' );

    # The template carries the zone and invents no names: what a recipe serves
    # it declares, and bin/new_config puts it in the aliases rendered above.
    unlike( $zone, qr/^autodiscover\s+IN\s+CNAME/m, 'it no longer invents autodiscover for a domain that serves no mail' );
    unlike( $zone, qr/^autoconfig\s+IN\s+CNAME/m,   'nor autoconfig' );
    unlike( $zone, qr/matrix/,                      'nor a matrix block of its own' );

    # Absolute already, and the pattern the MX record above should have
    # followed.  Asked of a zone that serves mail: the SRVs are written only
    # where something answers on the name they point at.
    like( zone( modules => ['mail'] ), qr/^_imaps\._tcp\s+IN\s+SRV\s+0\s+0\s+993\s+\Qmail.$DOMAIN\E\./m, 'an SRV target is absolute' );
};

subtest 'a record points only at a name the guest actually has' => sub {

    # The MX, the five SRVs and the autoconfig TXT all name a host the mail
    # recipe declares, so on a domain running no mail they would point at a name
    # with no record at all.
    my $without = zone();

    unlike( $without, qr/IN\s+MX\s/,  'no MX where nothing serves mail' ) or diag $without;
    unlike( $without, qr/IN\s+SRV\s/, 'nor the mail SRVs' )               or diag $without;
    unlike( $without, qr/mailconf=/,  'nor an autoconfig URL for a name nothing answers on' );
    unlike( $without, qr/_domainkey/, 'nor DKIM placeholders' );

    my $with = zone( modules => ['mail'] );

    like( $with, qr/IN\s+MX\s+10\s+\Qmail.$DOMAIN\E\./, 'and the MX is there where mail is served' );
    like( $with, qr/^_imaps\._tcp\s+IN\s+SRV/m,         'with the SRVs beside it' );
    like( $with, qr/mailconf=/,                         'and the autoconfig record' );
};

subtest 'the apex is the origin, not a name of its own' => sub {
    my $zone = zone();

    like( $zone, qr/^\$ORIGIN\s+\Q$DOMAIN\E\./m,               'the zone declares its origin' );
    like( $zone, qr/^\@\s+IN\s+A\s+192\.0\.2\.50/m,            'and the address is on the apex' );
    like( $zone, qr/^\@\s+300\s+IN\s+NS\s+\Qns1.$DOMAIN\E\./m, 'with an absolute nameserver' );
};

subtest 'the submission SRV record names the port postfix listens on' => sub {

    # Asked of a zone that serves mail, since the mail records are written only
    # where something answers on the name they point at.
    my $zone = zone( modules => ['mail'] );

    # RFC 6186 spells it _submission._tcp, and mail.postfix.master.tt runs
    # submission on 587.
    my ($record) = $zone =~ m/^(_submission\N*)$/m;
    is( ( split ' ', $record // q{} )[0], '_submission._tcp', 'on _submission._tcp' ) or diag $zone;
    like( $record, qr/SRV\s+0\s+0\s+587\s+\Qmail.$DOMAIN\E\./, 'at port 587 on the mail host' );
};

subtest 'the API config names the socket the recipe binds' => sub {
    local $Provisioner::Recipe::pdns::API_SOCKET = '/bogus/api.sock';
    my $recipe = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );

    like( $recipe->render_file( 'files/pdns.api.tt', %VARS, api_key => 'a-key' ), qr{/bogus/api[.]sock}, 'from $API_SOCKET' );
};

subtest 'zones for other guests, and where each one is delegated from' => sub {
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", <<'YAML' );
ns1.example.net:
    lexicon:
        dns_preference: pdns
    registrar:
        type: easydns
        key: a-registrar-key
    pdns:
        api_key: the-ns1-key
        authoritative_for:
            - lab.up.example.net
            - lab.ns1.example.net
            - ns1.example.net
            - up2.example.net
            - lab.up2.example.net
            - lab.other.net
            - lab.zone.test
ns2.example.net:
    pdns:
        authoritative_for:
            - up.example.net
YAML
    Provisioner::Cookbook->forget();

    my $recipe = Provisioner::Cookbook->load('pdns');
    my %opts   = ( domain => 'ns1.example.net' );
    my %up;

    %up = $recipe->upstream_of( 'lab.up.example.net', %opts );
    is( $up{credentials}{extra}[0]{value}, 'https://dnsapi.ns2.example.net', 'a zone below a zone of another pdns guest goes to that guest' );
    is_deeply( [ keys %{ $up{secrets} } ], ['/etc/lexicon/lab.up.example.net.token'], 'with a token of the name of the zone, which this guest needs' );
    is( $up{secrets}{'/etc/lexicon/lab.up.example.net.token'}{issue}{guest}, 'ns2.example.net', 'and which that guest issues' );
    like( $up{secrets}{'/etc/lexicon/lab.up.example.net.token'}{issue}{command}, qr/--zone[ ]up[.]example[.]net[.]/, 'in the zone that it holds' );

    %up = $recipe->upstream_of( 'lab.up2.example.net', %opts );
    is( $up{credentials}{extra}[0]{value}, $Provisioner::Recipe::pdns::API_SOCKET, 'a zone below another zone of this guest goes to this server' );
    is( $up{credentials}{key},             'the-ns1-key',                          'with its key' );
    ok( !$up{secrets}, 'and needs no token' );

    %up = $recipe->upstream_of( 'lab.ns1.example.net', %opts );
    is( $up{credentials}{type}, 'powerdns', 'a zone below this domain goes to whoever holds the zone of this domain, here its own server' );

    %up = $recipe->upstream_of( 'ns1.example.net', %opts );
    is( $up{credentials}{type}, 'easydns',         'the zone of this domain itself goes to its registrar, and not into itself' );
    is( $up{credentials}{key},  'a-registrar-key', 'with the credentials that the operator configured' );

    %up = $recipe->upstream_of( 'lab.other.net', %opts );
    is( $up{credentials}{type}, 'easydns', 'and so does any other zone' );

    is_deeply( { $recipe->upstream_of( 'lab.zone.test', %opts ) }, {}, 'under a reserved TLD, with nothing above, nothing is written' );

    my %secrets = $recipe->guest_secrets( '/bogus', 'ns1.example.net', authoritative_for => [ 'lab.up.example.net', 'lab.other.net' ] );
    is_deeply( [ keys %secrets ], ['/etc/lexicon/lab.up.example.net.token'], 'guest_secrets are the tokens of the zones that another guest delegates' );

    like( Test::Fatal::exception { $recipe->delegated_zones( domain => 'ns1.example.net', authoritative_for => ['example.net'] ) }, qr/registered[ ]domain/, 'a registered domain cannot be delegated' );
    is_deeply( [ $recipe->delegated_zones( domain => 'ns1.example.net', authoritative_for => ['A.Example.Net.'] ) ], ['a.example.net'], 'and its subdomain can, in lower case and without its dot' );

    my $script = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    )->render_file( 'files/pdns.delegations.sh.tt', %VARS, domain => 'ns1.example.net', main_ip => '192.0.2.53', authoritative_for => [ 'ns1.example.net', 'lab.zone.test' ] );
    like( $script, qr/^\@\s+300\s+IN[ ]NS\s+ns1[.]example[.]net[.]$/m,              'the zone names this domain as its nameserver' );
    like( $script, qr/^ns1[.]example[.]net[.][ ]300[ ]IN[ ]A\s+192[.]0[.]2[.]53$/m, 'with its address where it is in the zone' );
    my ($test_zone) = $script =~ m/^(\# lab[.]zone[.]test\n.*)/ms;
    unlike( $test_zone, qr/[ ]IN[ ]A[ ]/, 'and not where it is not' );
    like( $script, qr{^cat[ ]>[ ]/opt/lexicon/upstream/ns1[.]example[.]net[ ]}m, 'a zone with something above gets a shortcut to it' );
    like( $script, qr/^lexicon[ ]easydns[ ]\$COMMAND[ ]example[.]net[ ]/m,       'which names the zone above' );
    unlike( $script, qr{/opt/lexicon/upstream/lab[.]zone[.]test}, 'and a zone with nothing above gets none' );

    Provisioner::Cookbook->forget();
};

# The proxy through which the guests under those zones reach this one.
subtest 'the API proxy, only where the guest holds zones for others' => sub {
    my $recipe = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' );
    my $fresh  = sub { return $recipe->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => tempdir( CLEANUP => 1 ), distro => 'ubuntu' ) };
    my %held   = ( %VARS, api_key => 'the-server-key', authoritative_for => ["lab.$DOMAIN"], script_dir => '/bogus/bin', main_ip => '192.0.2.50' );

    is_deeply( [ $fresh->()->served_names(%held) ], ["dnsapi.$DOMAIN"], 'it serves dnsapi' );
    is_deeply( [ $fresh->()->served_names(%VARS) ], [],                 'and nothing without a zone for another guest' );

    my %required = ( Provisioner::Recipe::required_recipes( $fresh->(), %held ), $fresh->()->required_recipes(%held) );
    is_deeply( { $required{nginx}->() },                    { sites     => ["dnsapi.$DOMAIN"] },                                              'nginx gives it the name dnsapi' );
    is_deeply( { $required{'Provisioner::SSLRecipe'}->() }, { hostnames => ["dnsapi.$DOMAIN"] },                                              'which gets a certificate' );
    is_deeply( { $required{'Provisioner::DNSRecipe'}->() }, { hostnames => ["dnsapi.$DOMAIN"] },                                              'and a record, from this recipe itself where it holds the zone' );
    is_deeply( { $required{perl}->() },                     { cpan_deps => [ { install => [ 'Starman', 'PowerDNS::API::ACL~>= 0.002' ] } ] }, 'and perl installs the proxy and the server that runs it' );

    %required = $fresh->()->required_recipes(%VARS);
    ok( !$required{perl} && !$required{nginx}, 'none of which a guest with no zone for another guest gets' );

    my %opts = $fresh->()->validate( %held, transfer_ips => [qw{192.0.2.1 192.0.2.2}], ipmap => { $DOMAIN => '192.0.2.10', 'web.test.test' => '192.0.2.11', 'also.test.test' => '192.0.2.10' }, api_allow => ['198.51.100.0/24'] );
    is_deeply( $opts{api_allowed}, [qw{127.0.0.1 ::1 192.0.2.1 192.0.2.2 192.0.2.10 192.0.2.11 198.51.100.0/24}], 'the guest, this machine, every guest of the installation once, and what api_allow names' );

    my %pooled = $fresh->()->validate( %held, ip_pool => { cidr => '192.0.2.64/26', addresses => '192.0.2.200 192.0.2.10' }, ipmap => { $DOMAIN => '192.0.2.10' } );
    is_deeply( $pooled{api_allowed}, [qw{127.0.0.1 ::1 192.0.2.64/26 192.0.2.200 192.0.2.10}], 'and the whole pool, so that a guest built after this one gets in' );

    my $vhost = $fresh->()->render_file( 'files/pdns.acl.nginx.tt', %held, ipmap => { $DOMAIN => '192.0.2.10' } );
    my @rules = $vhost =~ m/^\s*((?:allow|deny)\s+\S+);$/mg;
    is_deeply( \@rules, [ 'allow 127.0.0.1', 'allow ::1', 'allow 192.0.2.10', 'deny all' ], 'the vhost allows those and denies the rest' );
    like( $vhost, qr{^\s*server_name[ ]dnsapi[.]\Q$DOMAIN\E;$}m, 'at the name dnsapi' );

    is( $fresh->()->render_file( 'files/pdns.acl.env.tt', %held ), "PDNS_API_KEY=the-server-key\n", 'the proxy gets the key of the server in its environment file' );
    like( $fresh->()->render_file( 'files/pdns.acl.dropin.tt', %held ), qr{^UMask=0002$}m, 'and pdns makes its socket writable by its group, where the proxy runs' );

    like( $fresh->()->render_file( 'files/pdns.global.tt', %held ),                   qr/^local-address=127[.]0[.]0[.]1,[ ]192[.]0[.]2[.]50:53$/m, 'the server answers on the address of the guest, which the zone above names' );
    like( $fresh->()->render_file( 'files/pdns.global.tt', %VARS, api_key => 'k' ),   qr/^local-address=127[.]0[.]0[.]1$/m,                        'and on loopback alone where it holds no zone for another guest' );
    like( Test::Fatal::exception { $fresh->()->validate( %held, main_ip => undef ) }, qr/has[ ]none[ ]yet/,                                        'a guest with no address of its own cannot hold one' );

    my $fragment = $fresh->()->render_file( 'ubuntu/pdns.tt', %held );
    like( $fragment, qr{^install[ ].*pdns-acl[.]dropin[.]conf[ ]}m, 'the fragment installs the drop-in' );
    ok( index( $fragment, 'pdns-acl.dropin.conf' ) < index( $fragment, 'systemctl restart pdns' ), 'before it restarts pdns, which reads it' );
    unlike( $fresh->()->render_file( 'ubuntu/pdns.tt', %VARS, api_key => 'k', script_dir => '/bogus/bin' ), qr{pdns-acl[.]service}, 'and installs no proxy without a zone for another guest' );
};

subtest 'what a guest under one of its zones gets' => sub {
    my $recipe = Provisioner::Cookbook->load('pdns');
    my $name   = "web.lab.$DOMAIN";

    my %credentials = $recipe->client_credentials( $DOMAIN, $name );
    is( $credentials{type},     'powerdns',                 'the powerdns provider of lexicon' );
    is( $credentials{key_file}, "/etc/lexicon/$name.token", 'with its token in a file' );
    is( $credentials{opts},     '--resolve-zone-name',      'asking the DNS which zone holds its name' );
    is_deeply( $credentials{extra}, [ { key => 'PDNS_SERVER', value => "https://dnsapi.$DOMAIN" } ], 'at the proxy of the guest that holds it' );

    my %secret = $recipe->client_secret( $DOMAIN, "lab.$DOMAIN", $name );
    my $token  = $secret{ $credentials{key_file} };
    ok( $token, 'the token is the file that the credentials name' ) or return;
    is( $token->{issue}{guest}, $DOMAIN, 'issued by the guest that holds the name' );
    ok( !$token->{ref}, 'and not kept in the store' );

    my $command = $token->{issue}{command};
    like( $command, qr/\Qtoken remove $name >\E/,                                          'the command replaces the token of that name' );
    like( $command, qr/\Qtoken add $name --zone lab.$DOMAIN. --name $name. --write\E/,     'with one that writes the name' );
    like( $command, qr/\Qgrant add $name --zone lab.$DOMAIN. --name '*.$name.' --write\E/, 'and the names below it' );
    like( $command, qr/[&][&][ ]echo[ ]"\$token"\z/,                                       'and prints it only when both grants are in' );

    like( Test::Fatal::exception { $recipe->client_secret( $DOMAIN, "lab.$DOMAIN", 'web;reboot' ) }, qr/not[ ]one/, 'a name that is not a DNS name never reaches the shell of root' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
