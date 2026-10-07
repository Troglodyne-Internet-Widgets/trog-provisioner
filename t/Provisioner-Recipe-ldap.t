#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-ldap.t - what the ldap recipe makes of github, and what
it makes without it

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use Cpanel::JSON::XS();

use FindBin::libs;

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);
my %G = (
    domain         => 'dir.test.test',
    install_dir    => '/opt/domains',
    script_dir     => '/root/bin',
    admin_user     => 'admin',
    admin_password => 'throwaway',
);

sub recipe {
    return Provisioner::Cookbook->load( 'ldap', distro => 'ubuntu' )->new(%PROV);
}

subtest 'without github' => sub {
    my %req = recipe()->required_recipes(%G);
    is_deeply( { $req{cron}->() },                                                 { files => { 'ldap-export' => 'ldap-export.cron' } }, 'cron installs the export and no sync' );
    is_deeply( { recipe()->guest_secrets( '/opt/domains', 'dir.test.test', %G ) }, {},                                                   'no token is asked for' );
    unlike( recipe()->render_global( %G, users => [] ), qr/ldap-github-sync/, 'and the fragment runs no sync' );
    is_deeply( [ grep { m/perl/ } recipe()->deps(%G) ], [], 'nor installs perl for one' );
};

subtest 'with github' => sub {
    my %opts = ( %G, github => { org => 'someorg' } );

    my %req = recipe()->required_recipes(%opts);
    is( { $req{cron}->() }->{files}{'ldap-github-sync'}, 'ldap-github-sync.cron', 'cron runs the sync' );

    my %secrets = recipe()->guest_secrets( '/opt/domains', 'dir.test.test', %opts );
    my $token   = $secrets{'/etc/ldap/github-sync.token'};
    is( $token->{ref}, 'secret:ldap/dir.test.test-github-token/password', 'the token comes from the store, per domain' );
    my $add = 'bin/add_secret --group ldap --title dir.test.test-github-token';
    like( exception { $token->{generate}->() }, qr/\Q$add\E/, 'and a store without one says how to add it, since none can be made' );

    my $conf = Cpanel::JSON::XS->new->decode( recipe()->render_file( 'files/ldap.github-sync.json.tt', %opts, users => [] ) );
    is( $conf->{org},         'someorg',                     'the sync is configured for the organization' );
    is( $conf->{base_dn},     'dc=dir,dc=test,dc=test',      'and the directory of the domain' );
    is( $conf->{admin_group}, 'github-admins',               'with the defaults of the schema' );
    is( $conf->{uid_base},    1000000,                       'all of them' );
    is( $conf->{token_file},  '/etc/ldap/github-sync.token', 'and the token where bin/provision puts it' );

    my $fragment = recipe()->render_global( %opts, users => [] );
    like( $fragment, qr{^/usr/local/sbin/ldap-github-sync$}m, 'the fragment runs the sync once' );
    ok( index( $fragment, 'ldap-configure.sh' ) < index( $fragment, 'ldap-reload.sh' ), 'and adds the schema before the reload, which refuses an attribute it does not know' );

    ok( ( grep { $_ eq 'libio-socket-ssl-perl' } recipe()->deps(%opts) ), 'the sync gets https' );
};

subtest 'the schema refuses' => sub {
    like( exception { recipe()->validate( %G, github => {} ) }, qr{/github/org:}, 'a github with no org' );
    like( exception { recipe()->validate( %G, github => { org => 'some org' } ) },                qr{/github/org:},         'an org that is no login' );
    like( exception { recipe()->validate( %G, github => { org => 'o', admin_group => 'A b' } ) }, qr{/github/admin_group:}, 'a group that is no group name' );
};

done_testing();
