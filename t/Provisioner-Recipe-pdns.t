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
use Test::MockModule();
use IPC::Run3();
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

    my %binned = $fresh->()->validate( %held, ip_pool => { cidr => '192.0.2.64/26', bins => { vpnclients => { cidr => '10.8.0.128/25' } } }, ipmap => { $DOMAIN => '192.0.2.10' } );
    is_deeply( $binned{api_allowed}, [qw{127.0.0.1 ::1 192.0.2.64/26 192.0.2.10}], 'but only the bin of the guests, because a VPN client publishes no records' );

    my $vhost = $fresh->()->render_file( 'files/pdns.acl.nginx.tt', %held, ipmap => { $DOMAIN => '192.0.2.10' } );
    my @rules = $vhost =~ m/^\s*((?:allow|deny)\s+\S+);$/mg;
    is_deeply( \@rules, [ 'allow 127.0.0.1', 'allow ::1', 'allow 192.0.2.10', 'deny all' ], 'the vhost allows those and denies the rest' );
    like( $vhost, qr{^\s*server_name[ ]dnsapi[.]\Q$DOMAIN\E;$}m, 'at the name dnsapi' );
    unlike( $vhost, qr{location[ ]/acme/}, 'and passes no ACME to a guest that runs no CA' );

    my $with_ca  = $fresh->()->render_file( 'files/pdns.acl.nginx.tt', %held, modules => [qw{pdns acmeca}] );
    my $location = qr!location[ ]/acme/[ ][{]!;
    my $upstream = qr!proxy_pass[ ]https://127[.]0[.]0[.]1:9000;!;
    like( $with_ca, qr/$location\s*$upstream/, 'while it passes /acme/ to the CA of a guest that runs one, for the guests under this one' );

    like( $fresh->()->render_file( 'files/pdns.acl.psgi.tt',   %held ), qr{open\([ ]my[ ]\$fh,[ ]'<',[ ]'\Q$Provisioner::Recipe::pdns::API_KEY_FILE\E'[ ]\)}, 'the proxy reads the key of the server from its file' );
    like( $fresh->()->render_file( 'files/pdns.acl.dropin.tt', %held ), qr{^UMask=0002$}m,                                                                    'and pdns makes its socket writable by its group, where the proxy runs' );

    like( $fresh->()->render_file( 'files/pdns.global.tt', %held ), qr/^local-address=127[.]0[.]0[.]1,[ ]192[.]0[.]2[.]50:53$/m, 'the server answers on the address of the guest, which the zone above names' );
    like( $fresh->()->render_file( 'files/pdns.global.tt', %held, main_ip => undef ), qr/^local-address=127[.]0[.]0[.]1$/m, 'and on loopback alone where the hypervisor gives the address later' );

    # Once for the guest, so that a domain layered onto it does not replace the
    # proxy of the guest.  The global targets run before those of the domains,
    # whose fragment restarts pdns.
    my $global = $fresh->()->render_file( 'ubuntu/pdns.global.tt', %held );
    like( $global,                                            qr{^install[ ].*pdns-acl[.]dropin[.]conf[ ]}m, 'the global fragment installs the drop-in' );
    like( $global,                                            qr{^install[ ].*pdns-acl[.]psgi[ ]}m,          'and the proxy' );
    like( $fresh->()->render_file( 'ubuntu/pdns.tt', %held ), qr{^systemctl[ ]restart[ ]pdns$}m,             'which the fragment of the domain restarts pdns after' );
};

# One server for the guest, so every domain on it presents one key, which the
# store keeps.  A key that each build made for itself was a 401 for every domain
# but the first, because pdns kept the key of the first build.
subtest 'the key of the API is the secret of the guest' => sub {
    my $recipe = Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' );
    my $fresh  = sub { return $recipe->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => tempdir( CLEANUP => 1 ), distro => 'ubuntu' ) };
    my $file   = $Provisioner::Recipe::pdns::API_KEY_FILE;

    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", <<'YAML' );
_shared:
    host.test.test:
        - tenant.test.test
host.test.test:
    pdns:
tenant.test.test:
    pdns:
alone.test.test:
    pdns:
        api_key: an-operator-key
YAML
    Provisioner::Cookbook->forget();

    my %host   = $fresh->()->guest_secrets( '/bogus/dir', 'host.test.test' );
    my %tenant = $fresh->()->guest_secrets( '/bogus/dir', 'tenant.test.test' );
    my %alone  = $fresh->()->guest_secrets( '/bogus/dir', 'alone.test.test' );

    is( $host{$file}{ref},   'secret:pdns/host.test.test-api-key/password', 'the store keeps the key of the guest' );
    is( $tenant{$file}{ref}, $host{$file}{ref},                             'and a domain layered onto it gets that one' );
    like( $host{$file}{generate}->(), qr/\A[[:xdigit:]]{64}\z/, 'which is random when nobody chose one' );
    is( $alone{$file}{generate}->(), 'an-operator-key', 'and the api_key of the guest when an operator did' );
    is( $host{$file}{owner},         'root:pdns',       'pdns and the proxy can read it' );

    my %shortcut = $fresh->()->socket_credentials();
    is( $shortcut{key_file}, $file, 'lexicon reads the key from that file' );
    is( $shortcut{key},      q{},   'and the payload holds none' );

    my $api  = $fresh->()->render_file( 'ubuntu/pdns.global.tt', %VARS, domain => 'host.test.test', script_dir => '/bogus/bin' );
    my $line = qq{KEY=\$\$(cat $file) && test -n "\$\$KEY" && printf 'api-key=%s\\n' "\$\$KEY" >> /etc/powerdns/pdns.d/api.conf};
    ok( ( grep { $_ eq $line } split( m/\n/, $api ) ), 'the server runs with it, and refuses an empty one' ) or diag $api;

    Provisioner::Cookbook->forget();
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

    my %grant  = ( recipe => 'pdns', guest => $DOMAIN, client => $name );
    my %secret = $recipe->issue_grant( \%grant );
    my $token  = $secret{ $credentials{key_file} };
    ok( $token, 'the token is the file that the credentials name' ) or return;
    is( $token->{issue}{guest}, $DOMAIN, 'issued by the authority' );
    ok( !$token->{ref}, 'and not kept in the store' );

    my %revocation = $recipe->revoke_grant( \%grant );
    is( $token->{issue}{command}, "/root/bin/pdns_client issue $name $DOMAIN", 'which runs pdns_client there, for the name, with the authority as its nameserver' );
    is( $revocation{command},     "/root/bin/pdns_client release $name",       'and bin/destroy runs it to remove them' );

    like( Test::Fatal::exception { $recipe->issue_grant( { %grant, client => 'web;reboot' } ) },      qr/not[ ]one/, 'a name that is not a domain never reaches the shell of root' );
    like( Test::Fatal::exception { $recipe->issue_grant( { %grant, client => 'Web.Example.Net' } ) }, qr/not[ ]one/, 'nor one in capitals, which the zone and the token would not match' );
    like( Test::Fatal::exception { $recipe->revoke_grant( { %grant, guest => 'ns.nosuchtld' } ) }, qr/not[ ]one/, 'nor a domain under a TLD that does not exist' );
    is( $recipe->checked_names( 'web.lab.zone.test', 'ns.example.net' ), 1, 'and a reserved TLD is a TLD here' );
};

subtest 'an alias in a zone of the registrar is published there, and not in this zone' => sub {
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine( domain_config => sub { return { registrar => { accounts => { partner => { type => 'route53', zones => ['partner.test'] } } } } } );

    my $zone = zone( aliases => { $DOMAIN => [ "www.$DOMAIN", 'old.partner.test' ] } );
    like( $zone, qr/^\Qwww.$DOMAIN\E\.\s+IN\s+CNAME\s+\@/m, 'an alias of the zone stays' ) or diag $zone;
    unlike( $zone, qr/partner/, 'and the alias of the other zone is not written here' )    or diag $zone;
};

subtest 'a zone that an account names this guest the authority of is built here, with its SOA and NS records' => sub {
    my $mock     = Test::MockModule->new('Provisioner::Cookbook');
    my $accounts = {
        ours   => { authority => "\U$DOMAIN.",        zones => [qw{Customer.test other.test}] },
        theirs => { authority => 'ns.elsewhere.test', zones => ['not-ours.test'] },
        hosted => { type      => 'easydns',           zones => ['hosted.test'] },
    };
    $mock->redefine( domain_config => sub { return { registrar => { accounts => $accounts } } } );

    my $recipe = sub {
        return Provisioner::Cookbook->load( 'pdns', distro => 'ubuntu' )->new(
            template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
            output_dir    => tempdir( CLEANUP => 1 ),
            distro        => 'ubuntu',
        );
    };
    my %opts = ( %VARS, nameservers => { ns2 => 'ns2.zone.test' }, api_key => 'a-key' );

    is_deeply( { $recipe->()->validate(%opts) }->{held_zones}, [qw{customer.test other.test}], 'the zones of the accounts that name it, and of no other' );

    my $script = $recipe->()->render_file( 'files/pdns.held_zones.tt', %opts );
    like( $script, qr{^\$ORIGIN[ ]customer[.]test[.]$}m,             'each zone gets a zone file' );
    like( $script, qr{^\@\s+IN\s+SOA\s+ns1[.]\Q$DOMAIN\E[.][ ]}m,    'whose SOA names this guest' );
    like( $script, qr{^\@[ ]300[ ]IN[ ]NS[ ]ns1[.]\Q$DOMAIN\E[.]$}m, 'and so does an NS record' );
    like( $script, qr{^\@[ ]300[ ]IN[ ]NS[ ]ns2[.]zone[.]test[.]$}m, 'beside the other nameservers of the installation' );
    my $asks = qr{sqlite3[ ]\S+zones[.]db[ ]"SELECT[ ].*};
    $asks = qr{${asks}name='customer[.]test'"};
    like( $script, qr{^$asks[ ][|][ ]grep[ ]-q[ ][.][ ][|][|][ ]}m, 'loaded only where the database does not hold it yet' );

    my $err;
    IPC::Run3::run3( [ qw{bash -n -c}, $script ], \undef, \undef, \$err );
    is( $? >> 8, 0, 'and bash reads the script' ) or diag $err;

    $mock->redefine( host_of => sub { return $DOMAIN } );
    is_deeply( { $recipe->()->validate( %opts, domain => "web.$DOMAIN", ipmap => { "web.$DOMAIN" => '192.0.2.50' } ) }->{held_zones}, [], 'and a domain layered onto this guest builds none of them again' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
