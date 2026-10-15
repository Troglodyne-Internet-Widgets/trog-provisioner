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
    domain       => 'index.test.test',
    install_dir  => '/opt/domains',
    admin_user   => 'someadmin',
    script_dir   => '/root/bin',
    main_ip      => '192.0.2.9',
    full_aliases => [qw{files.test.test www.index.test.test mail.index.test.test}],
);
my $conf = do { local ( @ARGV, $/ ) = "$dir/nginxdirindex.domain.conf"; <> }
  // q{};

# Each server block reads its names from the file that nginx writes for this
# site.  Provisioner::Recipe::nginx decides what is in it.
my @includes = $conf =~ m{^ \s* include \s+ (\S+) ; }xmg;
is_deeply( \@includes, [ ('/etc/nginx/names/index.test.test/nginxdirindex.conf') x 2 ], 'each server block includes the names of this site' );
unlike( $conf, qr/^ \s* server_name /xm, 'and names none itself' );

my %required = $r->required_recipes( domain => 'index.test.test' );
is_deeply( { $required{nginx}->() }, { sites => { nginxdirindex => { domain => 1 } } }, 'the site is declared to nginx as the one that serves the domain' );

Test::NoWarnings::had_no_warnings();

done_testing();
