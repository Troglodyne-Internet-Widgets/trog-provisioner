#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/new_config-subdomains.t - which names a domain ends up answering for, and
which recipe asked for each of them

=cut

# Asserting a file was generated is what this file does, and -f is how you ask.
## no critic (ValuesAndExpressions::ProhibitFiletest_f)

use FindBin;
use FindBin::libs;

# Never the installation's real configuration: what this asserts should not
# depend on which machine it runs on.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempdir tempfile};
use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();

use Provisioner::Cookbook();
use Trog::Credentials();
use Trog::Secrets();

File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAadminskey someadmin\n" );

# A throwaway store, because pdns keeps the key of its API there.  Seeded
# rather than mocked: prompt() hands back a credential this run already has.
Trog::Secrets->create( "$ENV{TROG_PROVISIONER_CONFIG}/secrets.kdbx", 'throwaway' );
Trog::Credentials->remember( 'keepass', 'throwaway' );

require Trog::HV;
require Trog::HV::Libvirt;

# The two facts the generator asks a hypervisor for, answered here so this runs
# on a machine that is not one.
my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
$hv_mock->redefine( virbr_ip  => sub { '192.168.122.1' } );
$hv_mock->redefine( sshd_port => sub { 22 } );

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

sub generate {
    my ( $domain, %recipes_for ) = @_;

    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/domains";
    mkdir "$tmpdir/data";
    mkdir "$tmpdir/data/$domain";

    my $pool = join( ' ', map { "192.0.2.$_" } 100 .. 199 );

    # One resolver on purpose, written as a scalar rather than a list.  That is
    # what an operator writes, and bin/new_config dereferenced it raw when it
    # wrote provision.conf -- so generating from this is what catches it coming
    # back.
    my %global = (
        data_source   => "$tmpdir/data",
        basedir       => "$tmpdir/domains",
        transfer_user => 'someadmin',
        admin_user    => 'someadmin',
        admin_email   => 'bogus@test.test',
        admin_gecos   => 'Test Test',
        gateway       => '192.0.2.254',
        resolvers     => '192.0.2.254',
        ip_pool       => { addresses => $pool },
        nameservers   => { ns1       => 'ns1.test.test', ns2 => 'ns2.test.test' },
    );

    my %recipes = (
        _base   => { _global => \%global },
        $domain => \%recipes_for,
    );

    my $recipe_file = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";
    File::Slurper::Temp::write_text( $recipe_file, YAML::XS::Dump( \%recipes ) );

    Provisioner::Cookbook->forget();

    my $err = exception {
        Trog::Provisioner::Config::Generator::main( '--recipes', $recipe_file, '--skip_ssh', $domain );
    };

    my $makefile = "$tmpdir/domains/$domain/Makefile";

    return ( $err, ( -f $makefile ? File::Slurper::read_text($makefile) : undef ), "$tmpdir/domains/$domain" );
}

# The names that the stopgap certificate of the makefile names.
sub stopgap_names {
    my ($makefile) = @_;
    my ($san)      = ( $makefile // q{} ) =~ m/subjectAltName=([^']+)/;
    my @names      = sort map { s/\ADNS://r } split m/,/, $san // q{};
    return @names;
}

# The names that a generated domain hands its certificate and its zone, out of
# domains.txt of letsencrypt and the names that the registrar publishes, so
# these are what the recipes on it handed over.
sub certificate_names {
    my ($dir) = @_;
    my $list = -f "$dir/domains.txt" ? File::Slurper::read_text("$dir/domains.txt") : q{};
    return [ sort split ' ', $list ];
}

sub zone_names {
    my ( $dir, $domain ) = @_;
    my $makefile   = -f "$dir/Makefile" ? File::Slurper::read_text("$dir/Makefile") : q{};
    my $nameserver = qr{(?:--nameserver[ ]\S+[ ])?};
    my ($names)    = $makefile =~ m{publish_dns_records[ ]$nameserver\Q$domain\E[ ]\S+[ ]([^\n]*)};
    return [ sort split ' ', $names // q{} ];
}

subtest 'a recipe says which names it serves' => sub {

    # The names are labels rather than whole names: configures in
    # Provisioner::Recipe puts the domain on the end of each.
    is_deeply( [ Provisioner::Cookbook->load('nginxproxy')->subdomains ],  ['www'],                            'the vhost of the domain serves www' );
    is_deeply( [ Provisioner::Cookbook->load('nginx')->subdomains ],       [],                                 'and nginx itself serves none, because not every vhost serves the domain' );
    is_deeply( [ Provisioner::Cookbook->load('roundcube')->subdomains ],   ['webmail'],                        'roundcube serves webmail' );
    is_deeply( [ sort Provisioner::Cookbook->load('mail')->subdomains ],   [qw{autoconfig autodiscover mail}], 'mail serves its own three' );
    is_deeply( [ sort Provisioner::Cookbook->load('matrix')->subdomains ], [qw{admin.matrix matrix}],          'matrix serves two' );

    # Served at the domain itself, deliberately: git.$domain is a directory
    # name here and was never guaranteed to resolve, which is why gogs writes
    # its clone URLs against the domain.
    is_deeply( [ Provisioner::Cookbook->load('gogs')->subdomains ], [], 'gogs serves none, being reached at the domain' );

    is_deeply( [ Provisioner::Recipe->subdomains ], [], 'and a recipe that says nothing serves none' );
};

subtest 'the stopgap certificate names the domain and its configured aliases' => sub {
    my ( $err, $makefile ) = generate( 'plain.test', ntp => undef, _global => { aliases => ['alt.plain.test'] } );
    is( $err, undef, 'the generation runs to the end' ) or diag $err;
    is_deeply( [ stopgap_names($makefile) ], [qw{alt.plain.test plain.test}], 'and nothing that a recipe serves' );
};

subtest 'a web server brings www with it, and nothing it does not serve' => sub {
    my ( $err, undef, $dir ) = generate( 'web.test', nginxproxy => { proxy_uri => 'run/bogus.sock' }, pdns => undef );
    is( $err, undef, 'the generation runs to the end' ) or diag $err;

    # dnsapi, because a guest under a reserved TLD holds its own zone in pdns,
    # and pdns serves its API there.
    is_deeply( certificate_names($dir),        [qw{dnsapi.web.test web.test www.web.test}], 'the certificate names www, because nginxproxy serves it, and no mail, because nothing serves that' );
    is_deeply( zone_names( $dir, 'web.test' ), [qw{dnsapi.web.test www.web.test}],          'and so does the zone' );
};

subtest 'a name belonging to a dependency is handed over as well' => sub {

    # roundcube is served at webmail. and requires mail, which serves mail,
    # autodiscover and autoconfig.  Asking what recipes.d names would find only
    # roundcube and nginxproxy: the names come from every recipe that the
    # depsolver settled on.
    my ( $err, undef, $dir ) = generate( 'mail.test', roundcube => { version => '1.6.0' }, nginxproxy => { proxy_uri => 'run/bogus.sock' }, pdns => undef );
    is( $err, undef, 'the generation runs to the end' ) or diag $err;

    my @served = qw{autoconfig.mail.test autodiscover.mail.test dnsapi.mail.test mail.mail.test webmail.mail.test www.mail.test};
    is_deeply( certificate_names($dir),         [ sort 'mail.test', @served ], 'the certificate names what each recipe serves' );
    is_deeply( zone_names( $dir, 'mail.test' ), \@served,                      'and the zone carries each of them' );
};

subtest 'the certificate list is the aliases, and invents nothing' => sub {
    my $recipe = Provisioner::Cookbook->load( 'letsencrypt', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );

    my $domains = $recipe->render_file(
        'files/ssl.domains.tt',
        domain      => 'cert.test',
        hostnames   => [ 'www.cert.test', 'matrix.cert.test' ],
        aliases     => { 'cert.test' => ['alt.cert.test'] },
        install_dir => '/opt/domains',
        admin_user  => 'someadmin',
        modules     => ['matrix'],
    );

    like( $domains, qr/\bwww[.]cert[.]test\b/,    'the aliases are listed' );
    like( $domains, qr/\bmatrix[.]cert[.]test\b/, 'including one a recipe declared' );
    like( $domains, qr/\balt[.]cert[.]test\b/,    'and the alias configured for the domain' );

    # A certificate must not cover a name the zone does not carry.
    unlike( $domains, qr/admin[.]matrix/, 'and it adds no name of its own for a recipe on the guest' )
      or diag $domains;
};

done_testing;
