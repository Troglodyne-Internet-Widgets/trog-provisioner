#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-tpsgi.t - C<tpsgi.ini> takes the directory of the application from tpsgi alone

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

# What bin/new_config hands a recipe: the globals that it declares, and then
# its own configuration.
sub tpsgi_ini {
    my (%conf) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'tpsgi', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    my %globals = ( basedir => '/bogus/configs', domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', user => 'bogus' );
    $recipe->generate_files( $dir, $recipe->takes(%globals), routers => ['lib/Bogus.pm'], %conf );
    return File::Slurper::read_text("$dir/tpsgi.ini");
}

subtest 'the basedir global stays out of tpsgi.ini' => sub {
    my $ini = tpsgi_ini();
    unlike( $ini, qr/^basedir/m, 'with no app_dir, tPSGI keeps its default, the directory of the domain' ) or diag $ini;
};

subtest 'app_dir is the basedir of tPSGI' => sub {
    my $ini = tpsgi_ini( app_dir => 'tCMS' );
    like( $ini, qr/^basedir=tCMS$/m, 'tPSGI changes into the directory of the application' ) or diag $ini;
};

Test::NoWarnings::had_no_warnings();

done_testing;
