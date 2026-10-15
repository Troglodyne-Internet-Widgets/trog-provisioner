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

# The aliases that bin/new_config hands every recipe.
$r->generate_files(
    $dir,
    domain      => 'index.test.test',
    install_dir => '/opt/domains',
    admin_user  => 'someadmin',
    script_dir  => '/root/bin',
    main_ip     => '192.0.2.9',
);
my $conf = do { local ( @ARGV, $/ ) = "$dir/nginxdirindex.domain.conf"; <> }
  // q{};

# Each server block reads its names from the file that nginx writes for the
# vhost of the domain.  Provisioner::Recipe::nginx decides what is in it.
my @includes = $conf =~ m{^ \s* include \s+ (\S+) ; }xmg;
is_deeply( \@includes, [ ('/etc/nginx/names/index.test.test.conf') x 2 ], 'each server block includes the names of the vhost of the domain' );
my @own = $conf =~ m{^ \s* server_name \s+ ([^;]+) ; }xmg;
is_deeply( \@own, [ ('www.index.test.test') x 2 ], 'and names www, which this recipe serves, itself' );

my %required = $r->required_recipes( domain => 'index.test.test' );
is_deeply( { $required{nginx}->( domain => 'index.test.test' ) }, { sites => [qw{index.test.test www.index.test.test}] }, 'the vhost is declared to nginx as the one that serves the domain, and www' );

Test::NoWarnings::had_no_warnings();

done_testing();
