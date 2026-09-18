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

File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAdogeskey doge\n" );

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

    my $pool = join( ' ', map { "192.168.1.$_" } 100 .. 199 );

    my $ipmap = <<"IPMAP";
[global]
ip=192.168.1.50
basedir=$tmpdir/domains
transfer_user=doge
admin_user=doge
admin_email=bogus\@test.test
admin_gecos=Test Test
gateway=192.168.1.254
resolvers=192.168.1.254
bridge_devname=ens4
dhcp_devname=ens3
[ip_pool]
addresses=$pool
[nameservers]
ns1=ns1.test.test
ns2=ns2.test.test
IPMAP

    my %recipes = (
        _base   => { _global => { data_source => "$tmpdir/data" } },
        $domain => \%recipes_for,
    );

    my ( $ih, $ipmap_file ) = tempfile();
    print {$ih} $ipmap;
    close($ih) or die "Could not close $ipmap_file: $!";

    my $recipe_file = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";
    File::Slurper::Temp::write_text( $recipe_file, YAML::XS::Dump( \%recipes ) );

    Provisioner::Cookbook->forget();

    my $err = exception {
        Trog::Provisioner::Config::Generator::main( '--ipmap', $ipmap_file, '--recipes', $recipe_file, '--skip_ssh', $domain );
    };

    my $makefile = "$tmpdir/domains/$domain/Makefile";

    return ( $err, ( -f $makefile ? File::Slurper::read_text($makefile) : undef ) );
}

# Every name the guest is told to answer for, out of the self-signed
# certificate the makefile makes before anything else runs.
#
# Read from there rather than from a variable inside the generator, because that
# list is what a guest actually ends up with: the same full_aliases reaches the
# zone, the nginx vhost and the ACME certificate, and this is the one place it
# is written down in full.
sub names_in {
    my ($makefile) = @_;
    return () unless defined $makefile;

    my ($san) = $makefile =~ m/subjectAltName=([^']+)/;
    return () unless $san;

    my @names = sort map { s/\ADNS://r } split m/,/, $san;

    return @names;
}

subtest 'a recipe says which names it serves' => sub {

    # The names are labels rather than whole names: bin/new_config puts the
    # domain on the end of each.
    is_deeply( [ Provisioner::Cookbook->load('nginx')->subdomains ],       ['www'],                            'nginx serves www' );
    is_deeply( [ Provisioner::Cookbook->load('roundcube')->subdomains ],   ['webmail'],                        'roundcube serves webmail' );
    is_deeply( [ sort Provisioner::Cookbook->load('mail')->subdomains ],   [qw{autoconfig autodiscover mail}], 'mail serves its own three' );
    is_deeply( [ sort Provisioner::Cookbook->load('matrix')->subdomains ], [qw{admin.matrix matrix}],          'matrix serves two' );

    # Served at the domain itself, deliberately: git.$domain is a directory
    # name here and was never guaranteed to resolve, which is why gogs writes
    # its clone URLs against the domain.
    is_deeply( [ Provisioner::Cookbook->load('gogs')->subdomains ], [], 'gogs serves none, being reached at the domain' );

    is_deeply( [ Provisioner::Recipe->subdomains ], [], 'and a recipe that says nothing serves none' );
};

subtest 'a domain gets the names its recipes serve, and no others' => sub {
    my ( $err, $makefile ) = generate( 'plain.test', ntp => undef );
    is( $err, undef, 'the generation runs to the end' ) or diag $err;

    # www and mail went to every domain in the ip map, whatever it ran.  A
    # domain serving neither has no use for either: the name resolved to a guest
    # with nothing listening, and the certificate covered it.
    my @names = names_in($makefile);
    is_deeply( \@names, ['plain.test'], 'a domain running neither a web server nor mail answers for itself alone' )
      or diag explain \@names;
};

subtest 'a web server brings www with it' => sub {
    my ( $err, $makefile ) = generate( 'web.test', nginx => undef );
    is( $err, undef, 'the generation runs to the end' ) or diag $err;

    my @names = names_in($makefile);
    ok( ( grep { $_ eq 'www.web.test' } @names ), 'www is there, because nginx serves it' )
      or diag explain \@names;
    ok( !( grep { $_ eq 'mail.web.test' } @names ), 'and mail is not, because nothing serves that' )
      or diag explain \@names;
};

subtest 'a name belonging to a dependency is added as well' => sub {

    # roundcube is served at webmail. and requires nginx, which serves www, and
    # mail, which serves mail.  Asking what recipes.d names would find only
    # webmail: the list has to be the one the depsolver settled on.
    my ( $err, $makefile ) = generate( 'mail.test', roundcube => { version => '1.6.0' } );
    is( $err, undef, 'the generation runs to the end' ) or diag $err;

    my @names = names_in($makefile);
    ok( ( grep { $_ eq 'webmail.mail.test' } @names ), 'webmail is there, which nothing used to give it' )
      or diag explain \@names;
    ok( ( grep { $_ eq 'www.mail.test' } @names ), 'and www, which arrived with the nginx roundcube requires' )
      or diag explain \@names;

    # config.inc.php names mail.$domain for IMAP and submission, so the recipe
    # that answers there has to be on the guest rather than assumed.
    ok( ( grep { $_ eq 'mail.mail.test' } @names ), 'and mail, which roundcube requires for the host its IMAP settings name' )
      or diag explain \@names;
};

subtest 'the certificate list is the aliases, and invents nothing' => sub {
    my $recipe = Provisioner::Cookbook->load( 'letsencrypt', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );

    my $domains = $recipe->render_file(
        'files/ssl.domains.tt',
        domain       => 'cert.test',
        full_aliases => [ 'www.cert.test', 'matrix.cert.test' ],
        install_dir  => '/opt/domains',
        admin_user   => 'doge',
        modules      => ['matrix'],
    );

    like( $domains, qr/\bwww[.]cert[.]test\b/,    'the aliases are listed' );
    like( $domains, qr/\bmatrix[.]cert[.]test\b/, 'including one a recipe declared' );

    # It named the matrix pair itself before, as a second copy of the rule in
    # pdns.zone.tt -- so a certificate could cover a name the zone did not.
    unlike( $domains, qr/admin[.]matrix/, 'and it adds no name of its own for a recipe on the guest' )
      or diag $domains;
};

done_testing;
