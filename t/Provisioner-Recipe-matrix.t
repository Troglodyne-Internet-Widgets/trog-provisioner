#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-matrix.t - the index page, the admin registration script, and
where notices come from

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use YAML::XS();

use FindBin::libs;

use Provisioner::Cookbook();

my $PASSWORD = 's3cr3t-admin-pw';

my $dir = tempdir( CLEANUP => 1 );
my $r   = Provisioner::Cookbook->load( 'matrix', distro => 'ubuntu' )->new(
    template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir    => $dir,
    distro        => 'ubuntu',
);
$r->generate_files(
    $dir,
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

sub rendered {
    my ($name) = @_;
    return do { local ( @ARGV, $/ ) = "$dir/$name"; <> }
      // q{};
}

# The server name is the identity of the homeserver, and it is not the name
# that nginxproxy serves the client API at.  The configuration above makes the
# two differ, so that a template that uses one for the other shows.
subtest 'synapse is the server that server_name names' => sub {
    my $hs = YAML::XS::Load( rendered('homeserver.yaml') );
    is( $hs->{server_name}, 'hs.test.test', 'homeserver.yaml names the server server_name, not matrix.<domain>' );
    is_deeply( $hs->{auto_join_rooms}, ['#general:hs.test.test'], 'and new accounts join a room on this server' );
};

subtest 'the index page names the homeserver synapse is' => sub {
    my $index = rendered('matrix.index.html');
    like( $index, qr{Home\ Server:\ https://matrix\.chat\.test\.test$}m, 'at its public URL, with no port nothing listens on' );
    like( $index, qr{^\s*\#general:hs\.test\.test$}m,                    'and the channels as room aliases on the server, #room:server_name' );
    like( $index, qr{^\s*\#random:hs\.test\.test$}m,                     'every one of them' );
};

subtest 'the admin registration script' => sub {
    my $script = rendered('matrix_register_admin.sh');
    my @args   = grep { index( $_, 'register_new_matrix_user' ) >= 0 } split m/\n/, $script;
    is( scalar @args, 1, 'runs register_new_matrix_user once' );
    unlike( $args[0] // q{}, qr/\Q$PASSWORD\E/, 'without the admin password on its command line' );
    like( $script, qr/^\Q$PASSWORD\E$/m, 'which it reads from a file instead' );
};

subtest 'notices come from smtp_from, whatever the login is' => sub {
    my ($from) = rendered('homeserver.yaml') =~ m/^\s+notif_from:\ (\N*)$/m;
    is( $from, '"%(app)s chat server <notify@test.test>"', 'the address as it was given' );

    my %good = ( server_name => 'matrix.test.test', admin_password => 'p', smtp_host => 'mail.test.test', smtp_user => 'notify', smtp_pass => 'p', smtp_from => 'notify@test.test' );
    ok( !exception { $r->validate(%good) }, 'a login that is not an address is fine' );
    like( exception { $r->validate( %good, smtp_from => 'notify' ) }, qr{/smtp_from:}, 'but a From that is not an address is refused' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
