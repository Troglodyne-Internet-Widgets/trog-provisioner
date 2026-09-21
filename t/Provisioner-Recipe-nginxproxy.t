#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-nginxproxy.t - which vhosts listen on IPv6

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my %BASE = (
    domain       => 'proxy.test.test',
    install_dir  => '/opt/domains',
    admin_user   => 'someadmin',
    script_dir   => '/root/bin',
    main_ip      => '192.0.2.9',
    full_aliases => [],
);

# The listen lines of the rendered vhost file, as "port" or "[::]:port".
sub listens {
    my (%opts) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    my $r   = Provisioner::Cookbook->load( 'nginxproxy', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    $r->generate_files( $dir, %BASE, %opts );

    my $text = do { local ( @ARGV, $/ ) = "$dir/nginx.domain.conf"; <> }
      // q{};
    return [ sort $text =~ m/^ \s* listen \s+ (\S+) /xmg ];
}

my %SPLIT = (
    80  => { ssl_redirect => 1 },
    443 => { ssl          => 1, proxy_uri => 'http://127.0.0.1:8008' },
);

subtest 'the ipv6 of the recipe covers every vhost' => sub {
    is_deeply( listens( proxy_uri => 'http://127.0.0.1:8008' ),            [qw{443 80 [::]:443 [::]:80}], 'on by default' );
    is_deeply( listens( proxy_uri => 'http://127.0.0.1:8008', ipv6 => 0 ), [qw{443 80}],                  'off for every vhost when it is off' );
};

# A recipe that depends on this one says so for the vhosts it asks for.
subtest 'a vhost can turn IPv6 off for itself' => sub {
    is_deeply(
        listens( vhosts => { 80 => $SPLIT{80}, 443 => { %{ $SPLIT{443} }, ipv6 => 0 } } ),
        [qw{443 80 [::]:80}],
        'only the vhost that said so loses its IPv6 listener'
    );
    is_deeply(
        listens( ipv6 => 0, vhosts => { 80 => { %{ $SPLIT{80} }, ipv6 => 1 }, 443 => $SPLIT{443} } ),
        [qw{443 80}],
        'and a vhost cannot turn it on when the recipe has it off'
    );
};

subtest 'matrix hands its own ipv6 to both of its vhosts' => sub {
    my $matrix = Provisioner::Cookbook->load( 'matrix', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => '/nonexistent',
        distro        => 'ubuntu',
    );
    my %required = $matrix->required_recipes( ipv6 => 0 );
    my %proxy    = $required{nginxproxy}->();
    is_deeply( { map { $_ => $proxy{vhosts}{$_}{ipv6} } keys %{ $proxy{vhosts} } }, { 80 => 0, 443 => 0 }, 'ipv6: 0 on matrix turns it off on 80 and 443' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
