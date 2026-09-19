#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-fail2ban.t - the jails that recipes declare, and the one
file that fail2ban makes of them

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();
use Provisioner::Recipe();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);
my %G = (
    domain      => 'jail.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'admin',
);

sub recipe {
    my ($name) = @_;
    return Provisioner::Cookbook->load( $name, distro => 'ubuntu' )->new(%PROV);
}

subtest 'a recipe that declares jails depends on fail2ban for them' => sub {
    my %req = Provisioner::Recipe::required_recipes( recipe('nginx'), %G );
    ok( $req{fail2ban}, 'nginx requires fail2ban' ) or return;
    is_deeply(
        { $req{fail2ban}->() },
        { jails => { 'nginx-http-auth' => { backend => 'auto' }, 'nginx-botsearch' => { backend => 'auto' } } },
        'and hands it the jails that fail2ban ships for nginx, reading its log file'
    );

    my %mail = Provisioner::Recipe::required_recipes( recipe('mail'), %G );
    is_deeply( [ sort keys %{ { $mail{fail2ban}->() }->{jails} } ], [qw{dovecot postfix}], 'mail hands it postfix and dovecot' );

    my %ntp = Provisioner::Recipe::required_recipes( recipe('ntp'), %G );
    ok( !$ntp{fail2ban}, 'and a recipe with no jails does not require it' );
};

subtest 'the jail of tpsgi is its own, and named for the domain' => sub {
    my %jails = recipe('tpsgi')->jails(%G);
    my $jail  = $jails{'tpsgi-jail.test.test'};
    ok( $jail, 'named for the domain, so that two domains on one guest do not collide' ) or return;
    is( $jail->{filter},  '',                                          'with no filter file to look for' );
    is( $jail->{logpath}, '/opt/domains/jail.test.test/log/tpsgi.log', 'reading the log of the domain' );
    is( $jail->{backend}, 'auto',                                      'as a file, not the journal' );
    like( $jail->{failregex},   qr/<HOST>/, 'with a failregex that names the host' );
    like( $jail->{datepattern}, qr/\A%%Y/,  'and a datepattern with its percent signs doubled for fail2ban' );
};

subtest 'the jails of every recipe on the guest reach fail2ban' => sub {
    my %domain_conf = ( nginx => {}, tpsgi => { routers => ['app.psgi'] } );
    Provisioner::Cookbook->resolve_dependencies(
        modules       => [qw{nginx tpsgi}],
        domain_conf   => \%domain_conf,
        global_config => {%G},
        distro        => 'ubuntu',
        provisioner   => \%PROV,
        domain        => $G{domain},
    );
    is_deeply( [ sort keys %{ $domain_conf{fail2ban}{jails} // {} } ], [qw{nginx-botsearch nginx-http-auth tpsgi-jail.test.test}], 'merged into one set' );
};

subtest 'one file, with a section for each jail' => sub {
    my %jails = ( recipe('tpsgi')->jails(%G), postfix => {} );
    my $file  = recipe('fail2ban')->render_file( 'files/fail2ban.jail.tt', %G, jails => \%jails );

    like( $file, qr/^\[postfix\]\nenabled[ ]=[ ]true\n\n/m,                'a shipped jail is only its name, enabled' );
    like( $file, qr/^\[tpsgi-jail[.]test[.]test\]\nenabled[ ]=[ ]true\n/m, 'a jail of our own is enabled too' );
    like( $file, qr/^filter[ ]=[ ]$/m,                                     'with an empty filter' );
    like( $file, qr/^failregex[ ]=[ ].*From[ ]<HOST>[ ]/m,                 'and its failregex as written, not HTML-escaped' );
    unlike( $file, qr/&lt;/, 'nothing in it is escaped' );
};

subtest 'a jail that is not a section of an INI file is refused' => sub {
    like( exception { recipe('fail2ban')->render_file( 'files/fail2ban.jail.tt', %G, jails => { 'no]good' => {} } ) },               qr{/jails:[ ]Properties[ ]not[ ]allowed}, 'a bracket in the name' );
    like( exception { recipe('fail2ban')->render_file( 'files/fail2ban.jail.tt', %G, jails => { ok        => { nested => {} } } ) }, qr{/jails/ok/nested:},                    'or an option that is not a string' );
};

done_testing();
