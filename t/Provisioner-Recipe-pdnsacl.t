#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-pdnsacl.t - what the proxy of the PowerDNS API is given,
and who may reach it

=cut

use Test::More;
use Test::NoWarnings;
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my $DOMAIN = 'dns.test.test';

# One configuration for every case: the server of this domain sets its own key.
my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
$cookbook->redefine( domain_config => sub { return { pdns => { api_key => 'the-server-key' } } } );
$cookbook->redefine( host_of       => sub { return } );

sub fresh {
    return Provisioner::Cookbook->load( 'pdnsacl', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

my %COMMON = ( domain => $DOMAIN, install_dir => '/bogus', admin_user => 'someadmin', script_dir => '/bogus/bin' );

subtest 'it serves dnsapi, and asks for what it runs on' => sub {
    my %required = Provisioner::Recipe::required_recipes( fresh(), domain => $DOMAIN );
    %required = ( %required, fresh()->required_recipes( domain => $DOMAIN ) );

    is_deeply( { $required{nginx}->() },                    { sites     => ["dnsapi.$DOMAIN"] }, 'nginx gives it the name dnsapi' );
    is_deeply( { $required{'Provisioner::SSLRecipe'}->() }, { hostnames => ["dnsapi.$DOMAIN"] }, 'which gets a certificate' );
    is_deeply( { $required{'Provisioner::DNSRecipe'}->() }, { hostnames => ["dnsapi.$DOMAIN"] }, 'and a record' );
    ok( $required{pdns}, 'it requires the server whose API it opens' );
    is_deeply( { $required{perl}->() }, { cpan_deps => [ { install => [ 'Starman', 'PowerDNS::API::ACL~>= 0.002' ] } ] }, 'and perl installs the proxy and the server that runs it' );
};

subtest 'it presents the key of the server, and reaches it on its socket' => sub {
    my %opts = fresh()->validate(%COMMON);
    is( $opts{api_key},    'the-server-key',               'the key that pdns has' );
    is( $opts{api_socket}, '/var/spool/powerdns/api.sock', 'and the socket where pdns listens' );

    my $env = fresh()->render_file( 'files/pdnsacl.env.tt', %COMMON );
    is( $env, "PDNS_API_KEY=the-server-key\n", 'the key goes to the service in its environment file' );

    my $dropin = fresh()->render_file( 'files/pdnsacl.pdns-dropin.tt', %COMMON );
    like( $dropin, qr{^UMask=0002$}m, 'and pdns makes that socket writable by its group, where the proxy runs' );
};

subtest 'only our own addresses reach the API' => sub {
    my %opts = fresh()->validate(
        %COMMON,
        transfer_ips => [qw{192.0.2.1 192.0.2.2}],
        ipmap        => { $DOMAIN => '192.0.2.10', 'web.test.test' => '192.0.2.11', 'also.test.test' => '192.0.2.10' },
        allow        => ['198.51.100.0/24'],
    );
    is_deeply( $opts{allowed}, [qw{127.0.0.1 ::1 192.0.2.1 192.0.2.2 192.0.2.10 192.0.2.11 198.51.100.0/24}], 'the guest, this machine, every guest of the installation once, and what allow names' );

    my $vhost = fresh()->render_file( 'files/pdnsacl.nginx.tt', %COMMON, ipmap => { $DOMAIN => '192.0.2.10' } );
    my @rules = $vhost =~ m/^\s*((?:allow|deny)\s+\S+);$/mg;
    is_deeply( \@rules, [ 'allow 127.0.0.1', 'allow ::1', 'allow 192.0.2.10', 'deny all' ], 'the vhost allows those and denies the rest' );
    like( $vhost, qr{^\s*server_name[ ]dnsapi[.]\Q$DOMAIN\E;$}m, 'at the name dnsapi' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
