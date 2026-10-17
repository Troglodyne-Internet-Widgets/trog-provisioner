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

# The proxy through which the guests that name this one reach it.
subtest 'the API proxy' => sub {
    my $recipe = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' );
    my $fresh  = sub { return $recipe->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => tempdir( CLEANUP => 1 ), distro => 'ubuntu' ) };
    my %held   = ( %VARS, api_key => 'the-server-key', script_dir => '/bogus/bin', main_ip => '192.0.2.50' );

    is_deeply( [ $fresh->()->served_names(%held) ], ["dnsapi.$DOMAIN"], 'it serves dnsapi' );

    my %required = ( Provisioner::Recipe::required_recipes( $fresh->(), %held ), $fresh->()->required_recipes(%held) );
    is_deeply( { $required{nginx}->() },       { sites     => ["dnsapi.$DOMAIN"] },                                              'nginx gives it the name dnsapi' );
    is_deeply( { $required{letsencrypt}->() }, { hostnames => ["dnsapi.$DOMAIN"] },                                              'which gets a certificate' );
    is_deeply( { $required{registrar}->() },   { hostnames => ["dnsapi.$DOMAIN"] },                                              'and a record, which the registrar publishes into the zone that this recipe holds' );
    is_deeply( { $required{perl}->() },        { cpan_deps => [ { install => [ 'Starman', 'PowerDNS::API::ACL~>= 0.002' ] } ] }, 'and perl installs the proxy and the server that runs it' );

    my %opts = $fresh->()->validate( %held, transfer_ips => [qw{192.0.2.1 192.0.2.2}], ipmap => { $DOMAIN => '192.0.2.10', 'web.test.test' => '192.0.2.11', 'also.test.test' => '192.0.2.10' }, api_allow => ['198.51.100.0/24'] );
    is_deeply( $opts{api_allowed}, [qw{127.0.0.1 ::1 192.0.2.1 192.0.2.2 192.0.2.10 192.0.2.11 198.51.100.0/24}], 'the guest, this machine, every guest of the installation once, and what api_allow names' );

    my %pooled = $fresh->()->validate( %held, ip_pool => { cidr => '192.0.2.64/26', addresses => '192.0.2.200 192.0.2.10' }, ipmap => { $DOMAIN => '192.0.2.10' } );
    is_deeply( $pooled{api_allowed}, [qw{127.0.0.1 ::1 192.0.2.64/26 192.0.2.200 192.0.2.10}], 'and the whole pool, so that a guest built after this one gets in' );

    my $vhost = $fresh->()->render_file( 'files/pdns.acl.nginx.tt', %held, ipmap => { $DOMAIN => '192.0.2.10' } );
    my @rules = $vhost =~ m/^\s*((?:allow|deny)\s+\S+);$/mg;
    is_deeply( \@rules, [ 'allow 127.0.0.1', 'allow ::1', 'allow 192.0.2.10', 'deny all' ], 'the vhost allows those and denies the rest' );
    like( $vhost, qr{^\s*server_name[ ]dnsapi[.]\Q$DOMAIN\E;$}m, 'at the name dnsapi' );
    unlike( $vhost, qr{location[ ]/acme/}, 'and passes no ACME to a guest that runs no CA' );

    my $with_ca  = $fresh->()->render_file( 'files/pdns.acl.nginx.tt', %held, modules => [qw{pdns acmeca}] );
    my $location = qr!location[ ]/acme/[ ][{]!;
    my $upstream = qr!proxy_pass[ ]https://127[.]0[.]0[.]1:9000;!;
    like( $with_ca, qr/$location\s*$upstream/, 'while it passes /acme/ to the CA of a guest that runs one, for the guests under this one' );

    is( $fresh->()->render_file( 'files/pdns.acl.env.tt', %held ), "PDNS_API_KEY=the-server-key\n", 'the proxy gets the key of the server in its environment file' );
    like( $fresh->()->render_file( 'files/pdns.acl.dropin.tt', %held ), qr{^UMask=0002$}m, 'and pdns makes its socket writable by its group, where the proxy runs' );

    like( $fresh->()->render_file( 'files/pdns.global.tt', %held ), qr/^local-address=127[.]0[.]0[.]1,[ ]192[.]0[.]2[.]50:53$/m, 'the server answers on the address of the guest, which the zone above names' );
    like( $fresh->()->render_file( 'files/pdns.global.tt', %held, main_ip => undef ), qr/^local-address=127[.]0[.]0[.]1$/m, 'and on loopback alone where the hypervisor gives the address later' );

    my $fragment = $fresh->()->render_file( 'ubuntu/pdns.tt', %held );
    like( $fragment, qr{^install[ ].*pdns-acl[.]dropin[.]conf[ ]}m, 'the fragment installs the drop-in' );
    ok( index( $fragment, 'pdns-acl.dropin.conf' ) < index( $fragment, 'systemctl restart pdns' ), 'before it restarts pdns, which reads it' );
};

subtest 'what a guest that names this one as its authority gets' => sub {
    my $recipe = Provisioner::Cookbook->load('pdns');
    my $name   = "web.lab.$DOMAIN";

    my %credentials = $recipe->client_credentials( $DOMAIN, $name );
    is( $credentials{type},     'powerdns',                 'the powerdns provider of lexicon' );
    is( $credentials{key_file}, "/etc/lexicon/$name.token", 'with its token in a file' );
    is( $credentials{opts},     '--resolve-zone-name',      'asking the DNS which zone holds its name' );
    is( $credentials{zone},     $name,                      'which is its own name, also for the names under it' );
    is_deeply( $credentials{extra}, [ { key => 'PDNS_SERVER', value => "https://dnsapi.$DOMAIN" } ], 'at the proxy of the authority' );

    my %secret = $recipe->client_secret( $DOMAIN, $name );
    my $token  = $secret{ $credentials{key_file} };
    ok( $token, 'the token is the file that the credentials name' ) or return;
    is( $token->{issue}{guest}, $DOMAIN, 'issued by the authority' );
    ok( !$token->{ref}, 'and not kept in the store' );

    is( $token->{issue}{command},                   "/root/bin/pdns_client issue $name $DOMAIN", 'which runs pdns_client there, for the name, with the authority as its nameserver' );
    is( $recipe->release_command( $DOMAIN, $name ), "/root/bin/pdns_client release $name",       'and bin/destroy runs it to remove them' );

    like( Test::Fatal::exception { $recipe->client_secret( $DOMAIN, 'web;reboot' ) },      qr/not[ ]one/, 'a name that is not a domain never reaches the shell of root' );
    like( Test::Fatal::exception { $recipe->client_secret( $DOMAIN, 'Web.Example.Net' ) }, qr/not[ ]one/, 'nor one in capitals, which the zone and the token would not match' );
    like( Test::Fatal::exception { $recipe->release_command( 'ns.nosuchtld', $name ) }, qr/not[ ]one/, 'nor a domain under a TLD that does not exist' );
    is( $recipe->checked_names( 'web.lab.zone.test', 'ns.example.net' ), 1, 'and a reserved TLD is a TLD here' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
