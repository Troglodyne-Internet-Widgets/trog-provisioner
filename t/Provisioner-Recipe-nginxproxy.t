#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-nginxproxy.t - which vhosts listen on IPv6, and what a
vhost that serves files sends to the application

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my %BASE = (
    domain      => 'proxy.test.test',
    install_dir => '/opt/domains',
    admin_user  => 'someadmin',
    script_dir  => '/root/bin',
    main_ip     => '192.0.2.9',
);

# The rendered vhost file.
sub vhost_file {
    my (%opts) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    my $r   = Provisioner::Cookbook->load( 'nginxproxy', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    $r->generate_files( $dir, %BASE, %opts );

    return do { local ( @ARGV, $/ ) = "$dir/nginx.domain.conf"; <> }
      // q{};
}

# The listen lines of the rendered vhost file, as "port" or "[::]:port".
sub listens {
    my (%opts) = @_;
    my $text = vhost_file(%opts);
    return [ sort $text =~ m/^ \s* listen \s+ (\S+) /xmg ];
}

# The body of the first location block with this argument, or undef.
sub location {
    my ( $text, $where ) = @_;
    my ($body) = $text =~ m/^ \s* location \s+ \Q$where\E \s+ \{ ( [^}]*? (?: \{ [^}]* \} [^}]*? )* ) \} /xm;
    return $body;
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

subtest 'a request with a query string goes to the application, not to a render' => sub {
    my $text = vhost_file( vhosts => { 443 => { ssl => 1, proxy_uri => 'run/app.sock', static_dir => 'www/static', nocache_prefix => '/secure' } } );
    my $root = location( $text, '/' );
    ok( defined $root, 'the vhost has a location for /' ) or return diag $text;

    my ($sent) = $root =~ m/ \b if \s* \( \$args \) \s* \{ \s* return \s+ (\d+) \s* ; \s* \} /x;
    ok( defined $sent, 'which returns a status for any query string' ) or return diag $root;
    like( $root, qr/ \b error_page \s+ \Q$sent\E \s+ = \s* \@default \s* ; /x, 'and sends that status to the named location of the application' );
    ok( index( $root, 'if ($args)' ) < index( $root, 'try_files' ), 'before it tries a file' );
    like( $text, qr/^ \s* location \s+ \@default \s+ \{ [^}]* proxy_pass /xm, 'and that named location proxies' );

    my $nocache = location( $text, '/secure' );
    ok( defined $nocache, 'the nocache_prefix has a location' ) or return diag $text;
    unlike( $nocache, qr/ \b if \b /x, 'which still serves an exact file whatever its query string' );

    unlike( vhost_file( proxy_uri => 'http://127.0.0.1:8008' ), qr/ \b if \s* \( \$args /x, 'a vhost with no static_dir proxies every request already' );
};

subtest 'the renders go out as UTF-8' => sub {
    my $text = vhost_file( proxy_uri => 'run/app.sock', static_dir => 'www/static' );
    like( location( $text, '/' ) // q{}, qr/^ \s* charset \s+ utf-8 \s* ; /xm, 'the location of the renders names their charset' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
