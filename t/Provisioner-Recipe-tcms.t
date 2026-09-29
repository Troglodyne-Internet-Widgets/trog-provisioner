#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-tcms.t - tCMS sends its log to syslog through tpsgi

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

subtest 'tpsgi is told to add the syslog output of tCMS' => sub {
    my %required = Provisioner::Cookbook->load( 'tcms', distro => 'ubuntu' )->required_recipes( domain => 'web.test.test', install_dir => '/bogus' );
    my %tpsgi    = $required{tpsgi}->( domain => 'web.test.test', install_dir => '/bogus' );

    # The tpsgi jail reads tpsgi.log, and nothing ships a file.  So the same
    # lines go to syslog too, which logshipper forwards.
    is_deeply( $tpsgi{loggers}, ['Trog::Log::Syslog'], 'the logger that tCMS ships' );

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'tpsgi', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    $recipe->generate_files( $dir, domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', user => 'bogus', %tpsgi );
    like( File::Slurper::read_text("$dir/tpsgi.ini"), qr/^loggers[ ]=[ ]Trog::Log::Syslog$/m, 'and tpsgi.ini names it' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
