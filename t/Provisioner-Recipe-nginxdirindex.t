#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-nginxdirindex.t - the names the directory index answers to

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my $dir = tempdir( CLEANUP => 1 );
my $r   = Provisioner::Cookbook->load( 'nginxdirindex', distro => 'ubuntu' )->new(
    template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir    => $dir,
    distro        => 'ubuntu',
);

# bin/new_config gives every domain www and mail aliases.
$r->generate_files(
    $dir,
    domain       => 'index.test.test',
    install_dir  => '/opt/domains',
    admin_user   => 'doge',
    script_dir   => '/root/bin',
    main_ip      => '192.168.1.9',
    full_aliases => [qw{files.test.test www.index.test.test mail.index.test.test}],
);
my $conf = do { local ( @ARGV, $/ ) = "$dir/nginxdirindex.domain.conf"; <> }
  // q{};

# nginx reports a name that two server blocks on one port both claim as a
# conflict, and one with a comma on it matches no request.
my @lists = $conf =~ m/^ \s* server_name \s+ ([^;]+) ; /xmg;
is( scalar @lists, 2, 'one server_name for each server block' );
foreach my $list (@lists) {
    is_deeply( [ split ' ', $list ], [qw{index.test.test files.test.test www.index.test.test mail.index.test.test}], 'the domain and its aliases, each once and space separated' );
}

Test::NoWarnings::had_no_warnings();

done_testing();
