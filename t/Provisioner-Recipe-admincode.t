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

# The git recipe scans these for their ssh host keys, and a host that serves
# no ssh gives it nothing, so its guest test fails.
subtest 'the host keys it asks git for are those of the host that serves ssh' => sub {
    my %git       = fresh()->required_recipes();
    my $hosts_for = sub {
        my (@urls) = @_;
        my %given  = ( admin_user => 'someadmin', repos_from => [ map { { api_url => $_ } } @urls ] );
        my %asked  = $git{git}->(%given);
        return $asked{accounts}{someadmin}{hosts};
    };

    is_deeply( $hosts_for->('https://api.github.com/'),                                   ['github.com'],                    'GitHub serves ssh from github.com, not from its API host' );
    is_deeply( $hosts_for->('https://git.test.test/api/v1'),                              ['git.test.test'],                 'a forge that serves both from one host is asked about that host' );
    is_deeply( $hosts_for->('https://ghe.test.test/api/v3'),                              ['ghe.test.test'],                 'and so is GitHub Enterprise' );
    is_deeply( $hosts_for->( 'https://api.github.com/', 'https://git.test.test/api/v1' ), [ 'github.com', 'git.test.test' ], 'each api_url for itself' );
};

# The settings file is the claude recipe's, and its target can run after this
# one, so the clones are added once every target is done.
subtest 'the checkouts are working directories of the agent only on a guest that runs claude' => sub {
    my $alone = fresh()->render( %COMMON, modules => [qw{admincode}] );
    unlike( $alone, qr/claude_settings/, 'a guest without claude leaves its settings alone' );

    my $with   = fresh()->render( %COMMON, modules => [qw{admincode claude}] );
    my $queued = 'queue_postrun_task /root/bin/claude_settings add-repos /opt/domains/code.test.test/src /opt/domains/code.test.test/.claude/settings.json';
    ok( index( $with, $queued ) >= 0, 'a guest with it adds the basedir clones to the settings of the agent, after every target' ) or diag $with;
};

subtest 'the extra packages install at first boot, with the rest' => sub {
    my @deps = fresh()->deps( extra_pkgs => [qw{tig tmux}] );
    ok( ( grep { $_ eq 'tig' } @deps ) && ( grep { $_ eq 'tmux' } @deps ), 'the extra_pkgs of the operator are deps' );
    ok( ( grep { $_ eq 'git' } fresh()->deps() ),                          'and with none, what the clone needs still is' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
