#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-matrix.t - the index page and the admin registration script

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};

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
    admin_user     => 'doge',
    script_dir     => '/root/bin',
    main_ip        => '192.168.1.9',
    server_name    => 'matrix.chat.test.test',
    admin_password => $PASSWORD,
    smtp_host      => 'mail.test.test',
    smtp_user      => 'notify@test.test',
    smtp_pass      => 'smtp-pass',
    smtp_domain    => 'test.test',
    channels       => [qw{general random}],
);

sub rendered {
    my ($name) = @_;
    return do { local ( @ARGV, $/ ) = "$dir/$name"; <> }
      // q{};
}

# homeserver.yaml makes synapse matrix.<domain>, and nginxproxy serves it on 443.
subtest 'the index page names the homeserver synapse is' => sub {
    my $index = rendered('matrix.index.html');
    like( $index, qr{Home\ Server:\ https://matrix\.chat\.test\.test$}m, 'at its public URL, with no port nothing listens on' );
    like( $index, qr{^\s*\#general:matrix\.chat\.test\.test$}m,          'and the channels as room aliases, #room:server' );
    like( $index, qr{^\s*\#random:matrix\.chat\.test\.test$}m,           'every one of them' );
};

subtest 'the admin registration script' => sub {
    my $script = rendered('matrix_register_admin.sh');
    my @args   = grep { m/register_new_matrix_user/ } split m/\n/, $script;
    is( scalar @args, 1, 'runs register_new_matrix_user once' );
    unlike( $args[0] // q{}, qr/\Q$PASSWORD\E/, 'without the admin password on its command line' );
    like( $script, qr/^\Q$PASSWORD\E$/m, 'which it reads from a file instead' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
