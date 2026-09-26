#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-admincode.t - which guests smoke the Perl repositories they check out

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

my %COMMON = (
    domain       => 'code.test.test',
    install_dir  => '/opt/domains',
    admin_user   => 'someadmin',
    script_dir   => '/root/bin',
    full_aliases => [],
    basedir      => 'src',
    repos_from   => [ { api_url => 'https://bogus.test.test/api', token => 'bogus', repos_for => ['bogus'] } ],
);

# A fresh recipe per case: validated() memoises onto the object, so a second
# render through the same one answers with the first one's options.
sub fresh {
    return Provisioner::Cookbook->load( 'admincode', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

# The smoke runs cpan_install, which installs into the perl that the perl recipe
# builds.  perllsp does not require that recipe, so a guest can have it alone.
subtest 'the checkouts are smoked only on a guest that builds a perl' => sub {
    my $alone = fresh()->render( %COMMON, modules => [qw{admincode perllsp}] );
    unlike( $alone, qr/smoke_perl_modules/, 'a guest with perllsp and no perl queues no smoke' );

    my $built = fresh()->render( %COMMON, modules => [qw{admincode perl perllsp}] );
    like( $built, qr/smoke_perl_modules/, 'a guest with the perl recipe does' );
};

subtest 'the extra packages install at first boot, with the rest' => sub {
    my @deps = fresh()->deps( extra_pkgs => [qw{tig tmux}] );
    ok( ( grep { $_ eq 'tig' } @deps ) && ( grep { $_ eq 'tmux' } @deps ), 'the extra_pkgs of the operator are deps' );
    ok( ( grep { $_ eq 'git' } fresh()->deps() ),                          'and with none, what the clone needs still is' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
