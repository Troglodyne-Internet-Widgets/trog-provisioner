#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-matrix.t - the names of the homeserver, the page of the
domain, its old signing keys, the admin registration script, and where notices
come from

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use Test::MockModule();
use File::Temp qw{tempdir};
use Cpanel::JSON::XS();
use YAML::XS();

use FindBin::libs;

use Provisioner::Cookbook();

my $PASSWORD = 's3cr3t-admin-pw';

my %CONFIG = (
    domain         => 'chat.test.test',
    install_dir    => '/opt/domains',
    admin_user     => 'someadmin',
    script_dir     => '/root/bin',
    main_ip        => '192.0.2.9',
    server_name    => 'hs.test.test',
    admin_password => $PASSWORD,
    smtp_host      => 'mail.test.test',
    smtp_user      => 'notify@test.test',
    smtp_pass      => 'smtp-pass',
    smtp_from      => 'notify@test.test',
    channels       => [qw{general random}],
);

# The configuration of chat.test.test that the recipe reads from the cookbook:
# its aliases, and whether its nginx has a relay.
my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
my %domain;
$cookbook->redefine( configuration => sub { return { 'chat.test.test' => {%domain} } } );

sub recipe {
    my $dir = tempdir( CLEANUP => 1 );
    return Provisioner::Cookbook->load( 'matrix', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
}

# Each file that the recipe renders for %CONFIG and %more, by name.
sub rendered (%more) {
    my $dir = tempdir( CLEANUP => 1 );
    recipe()->generate_files( $dir, %CONFIG, %more );
    my %text;
    foreach my $name (qw{homeserver.yaml matrix.index.html matrix.nginx.conf matrix_register_admin.sh}) {
        $text{$name} = do { local ( @ARGV, $/ ) = "$dir/$name"; <> }
          // q{};
    }
    return %text;
}

# The body of the return of a location of a rendered vhost, decoded.
sub well_known ( $conf, $path ) {
    my ($body) = $conf =~ m!location[ ]=[ ]\Q$path\E[ ][{] [^}]*? return[ ]200[ ]'([^']*)'! or return;
    return Cpanel::JSON::XS->new->decode($body);
}

# The server name is the identity of the homeserver, and it is not the name
# that the vhost of the homeserver is called.  The configuration above makes the
# two differ, so that a template that uses one for the other shows.
subtest 'synapse is the server that server_name names' => sub {
    %domain = ();
    my %text = rendered();
    my $hs   = YAML::XS::Load( $text{'homeserver.yaml'} );
    is( $hs->{server_name}, 'hs.test.test', 'homeserver.yaml names the server server_name, not matrix.<domain>' );
    is_deeply( $hs->{auto_join_rooms}, ['#general:hs.test.test'], 'and new accounts join a room on this server' );
    is( $hs->{public_baseurl}, 'https://hs.test.test:8448/', 'clients reach it at server_name, on 8448, where clients of an existing server already do' );
    ok( !exists $hs->{federation_domain_whitelist}, 'and it federates with any server, not only with itself' );
};

subtest 'the vhost of the homeserver says where it is' => sub {
    %domain = ();
    my $conf = { rendered() }->{'matrix.nginx.conf'};
    is_deeply( well_known( $conf, '/.well-known/matrix/server' ), { 'm.server'     => 'hs.test.test:8448' },                         'other servers federate with server_name on 8448' );
    is_deeply( well_known( $conf, '/.well-known/matrix/client' ), { 'm.homeserver' => { base_url => 'https://hs.test.test:8448' } }, 'and clients find the public_baseurl, with no slash at the end' );
};

subtest 'the page of the domain says how to connect' => sub {
    %domain = ();
    my $index = { rendered() }->{'matrix.index.html'};
    like( $index, qr{<code>https://hs\.test\.test:8448</code>}, 'the homeserver at its public URL' );
    like( $index, qr{<code>\#general:hs\.test\.test</code>},    'and the channels as room aliases on the server, #room:server_name' );
    like( $index, qr{<code>\#random:hs\.test\.test</code>},     'every one of them' );
    like( $index, qr{needs[ ]an[ ]email[ ]address},             'and that registration needs an email address, as registrations_require_3pid says' );
    unlike( $index, qr{<img}, 'with no pictures' );
};

subtest 'the names that the relay passes to the guest' => sub {
    %domain = ( _global => { aliases => [qw{chat.other.test matrix.chat.test.test}] }, nginx => { relay => 'relay.test.test' } );
    my %required = recipe()->required_recipes(%CONFIG);
    my %asked    = $required{nginx}->();
    is_deeply( $asked{sites}, [qw{matrix.chat.test.test admin.matrix.chat.test.test}], 'the vhosts of the homeserver and of the admin interface' );
    is_deeply(
        $asked{public_names},
        {
            'chat.test.test'  => { vhost => 'chat.test.test' },
            'chat.other.test' => { vhost => 'chat.test.test' },
            'hs.test.test'    => { vhost => 'matrix.chat.test.test', ports => { 8448 => 8449 } },
        },
        'the domain and its alias go to the page, server_name to the vhost of the homeserver, which the relay alone passes through on 8448, to 8449 of the guest, and an alias that the recipe serves itself stays off'
    );
    my %limits = recipe()->rate_limits(%CONFIG);
    is_deeply( [ sort keys %limits ], [ 8448, 8449 ], 'the guest opens 8448, and the port where the relay passes 8448 through' );
    my $conf = { rendered() }->{'matrix.nginx.conf'};
    like( $conf, qr{^\s*listen[ ]8449[ ]ssl[ ]proxy_protocol;$}m,   'where the vhost of the homeserver listens with the PROXY protocol' );
    like( $conf, qr{^\s*server_name[ ]matrix\.chat\.test\.test;$}m, 'and gets server_name from the file of the proxy, not its own line' );

    %domain   = ();
    %required = recipe()->required_recipes(%CONFIG);
    %asked    = $required{nginx}->();
    ok( !exists $asked{public_names}, 'without a relay, the recipe asks for no public name, and so no port of its own' );
    is_deeply( [ keys %{ { recipe()->rate_limits(%CONFIG) } } ], [8448], 'and opens 8448 alone' );
    my ($names) = { rendered() }->{'matrix.nginx.conf'} =~ m/^\s*server_name[ ]([^;]*);$/m;
    is( $names, 'matrix.chat.test.test hs.test.test', 'and the vhost answers for server_name itself' );
};

subtest 'server_name cannot be a name of the vhost of the domain' => sub {
    %domain = ( _global => { aliases => ['chat.other.test'] } );
    foreach my $name (qw{chat.test.test www.chat.test.test chat.other.test}) {
        like( exception { rendered( server_name => $name ) }, qr/server_name[ ]is[ ]\Q$name\E,[ ]which[ ]the[ ]vhost/, "$name is refused" );
    }
    is( exception { rendered( server_name => 'matrix.chat.test.test' ) }, undef, 'but the name of the vhost of the homeserver is fine' );
};

subtest 'the keys that the homeserver signed with before go to old_signing_keys' => sub {
    %domain = ();
    my %old = (
        'ed25519:a_old1' => { public => 'A' x 43, expired_ts => 1_600_000_000_000 },
        'ed25519:a_old2' => { public => 'B' x 43, expired_ts => 1_700_000_000_000 },
    );
    my $hs = YAML::XS::Load( { rendered( old_signing_keys => \%old ) }->{'homeserver.yaml'} );
    is_deeply(
        $hs->{old_signing_keys},
        { map { $_ => { key => $old{$_}{public}, expired_ts => $old{$_}{expired_ts} } } keys %old },
        'each under its key ID, with its public half as key, and when it expired'
    );

    my %good = ( domain => 'chat.test.test', server_name => 'hs.test.test', admin_password => 'p', smtp_host => 'mail.test.test', smtp_user => 'notify', smtp_pass => 'p', smtp_from => 'notify@test.test' );
    like( exception { recipe()->validate( %good, old_signing_keys => { 'a_old1' => $old{'ed25519:a_old1'} } ) }, qr{/old_signing_keys:}, 'a key ID without its algorithm is refused' );
    like( exception { recipe()->validate( %good, old_signing_keys => { 'ed25519:a_old1' => { public                              => 'A' x 43 } } ) }, qr{/expired_ts:}, 'and a key with no expiry' );
    like( exception { recipe()->validate( %good, old_signing_keys => { 'ed25519:a_old1' => { %{ $old{'ed25519:a_old1'} }, public => 'A' x 44 } } ) }, qr{/public:},     'and a public half that is not 32 bytes in base64 without padding' );
};

subtest 'the admin registration script' => sub {
    %domain = ();
    my $script = { rendered() }->{'matrix_register_admin.sh'};
    my @args   = grep { index( $_, 'register_new_matrix_user' ) >= 0 } split m/\n/, $script;
    is( scalar @args, 1, 'runs register_new_matrix_user once' );
    unlike( $args[0] // q{}, qr/\Q$PASSWORD\E/, 'without the admin password on its command line' );
    like( $script, qr/^\Q$PASSWORD\E$/m, 'which it reads from a file instead' );
};

subtest 'notices come from smtp_from, whatever the login is' => sub {
    %domain = ();
    my ($from) = { rendered() }->{'homeserver.yaml'} =~ m/^\s+notif_from:\ (\N*)$/m;
    is( $from, '"%(app)s chat server <notify@test.test>"', 'the address as it was given' );

    my %good = ( domain => 'chat.test.test', server_name => 'matrix.test.test', admin_password => 'p', smtp_host => 'mail.test.test', smtp_user => 'notify', smtp_pass => 'p', smtp_from => 'notify@test.test' );
    ok( !exception { recipe()->validate(%good) }, 'a login that is not an address is fine' );
    like( exception { recipe()->validate( %good, smtp_from => 'notify' ) }, qr{/smtp_from:}, 'but a From that is not an address is refused' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
