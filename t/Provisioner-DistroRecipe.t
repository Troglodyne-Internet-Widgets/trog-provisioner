#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-DistroRecipe.t - what a distribution has to answer for

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();

# The system under test, and the parent of the package below -- which critic
# cannot see, `use parent` naming it in a string.
## no critic (ProhibitUnusedImports)
use Provisioner::DistroRecipe();

# A distribution that has answered nothing, which is what a new one starts as.
{

    package Provisioner::Recipe::silentdistro;
    use parent -norequire, 'Provisioner::DistroRecipe';
}

sub silent {
    return bless(
        {
            template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
            output_dir    => tempdir( CLEANUP => 1 ),
        },
        'Provisioner::Recipe::silentdistro'
    );
}

subtest 'a distribution that has answered nothing says so, per question' => sub {
    my $distro = silent();

    foreach my $question (qw{packager base_image packager_invocation packager_up_invocation packager_remove_invocation}) {
        like(
            exception { $distro->$question() },
            qr/\bsilentdistro\b.*\bdoes not say what its $question is/,
            "$question dies naming itself and the question"
        );
    }
};

subtest 'every distro recipe depends on the vm recipe' => sub {

    # A guest is a distribution running on a machine, and those are two
    # different sets of answers.  This is what says the second follows from the
    # first, so that the vm recipe is depsolved and configured like anything
    # else rather than being reached for directly.
    my %required = silent()->required_recipes();
    ok( exists $required{vm}, 'vm is required' );
    is( ref $required{vm}, 'CODE', 'as a recipe dependency, with its options computed' );

    my %required_by_ubuntu = Provisioner::Cookbook->load('ubuntu')->new( template_dirs => [], output_dir => tempdir( CLEANUP => 1 ) )->required_recipes();
    ok( exists $required_by_ubuntu{vm}, 'and a real distro recipe inherits that rather than having to say it' );
};

subtest 'neither director is a module of the guest makefile' => sub {

    # Not merely that they render no fragment -- bin/new_config skips a recipe
    # with no template anyway.  `modules` is handed to every template and every
    # recipe as the list of what is on this guest, and neither of these is.
    my $dir = tempdir( CLEANUP => 1 );
    foreach my $director (qw{ubuntu vm}) {
        my $recipe = Provisioner::Cookbook->load($director)->new( template_dirs => [], output_dir => $dir );
        ok( !$recipe->is_module, "$director directs the build rather than running in it" );
    }

    ok( Provisioner::Cookbook->load('nginx')->new( template_dirs => [], output_dir => $dir )->is_module, 'while an ordinary recipe is a module' );
};

subtest 'a distribution names its own template directory' => sub {
    is( silent()->template_subdir,                              'silentdistro', 'which is the recipe name' );
    is( Provisioner::Cookbook->load('ubuntu')->template_subdir, 'ubuntu',       'asked of the class as readily as of an object' );
};

subtest 'the four files a guest boots from are ordinary template_files' => sub {
    my %files = Provisioner::Cookbook->load('ubuntu')->new( template_dirs => [], output_dir => tempdir( CLEANUP => 1 ) )->template_files();

    is_deeply(
        [ sort values %files ],
        [qw{meta-data network-config setup.sh user-data}],
        'declared the way any other recipe declares what it generates'
    );

    # Keyed on the distribution, so a second one gets its own set by being named
    # rather than by overriding this.
    ok( ( grep { m/\Aubuntu[.]/ } keys %files ) == scalar keys %files, 'out of that distribution own directory' );
};

subtest 'global_defaults: what _global holds when nobody wrote it down' => sub {
    my %defaults = Provisioner::Cookbook->load('ubuntu')->global_defaults;

    is_deeply( \%defaults, { mirror => q{}, cache => q{}, cpan_notest => 1 }, 'every setting the schema defaults, at its default' );

    # Its absence is how enrich knows to follow the mirror, so a default laid
    # under _global would switch that off on every guest.
    ok( !exists $defaults{mirror_insecure}, 'and nothing for the setting that declares none' );
};

subtest 'cache_uri: the fetch cache, as a URL a guest can append a path to' => sub {
    my $distro = Provisioner::Cookbook->load('ubuntu');
    my %fleet  = ( domain => 'guest.test.test', ipmap => { 'cache.test.test' => '192.168.1.9' } );

    is( $distro->cache_uri(%fleet), q{}, 'none configured is none' );
    is( $distro->cache_uri( %fleet, cache => 'http://cache.test.test:8080/' ), 'http://cache.test.test:8080', 'a URL as written, less the slash every path is appended after' );
    is( $distro->cache_uri( %fleet, cache => 'cache.test.test' ),              'http://192.168.1.9',          'a name in the pool is its address' );
    is( $distro->cache_uri( %fleet, cache => 'cache.test.test:8080' ),         'http://192.168.1.9:8080',     'with its port, when it is not on 80' );
    is( $distro->cache_uri( %fleet, cache => 'http://cache.test.test:8080' ),  'http://cache.test.test:8080', 'and a URL keeps its own' );

    my $said = q{};
    {
        local *STDOUT;
        open( STDOUT, '>', \$said ) or die $!;
        is( $distro->cache_uri( %fleet, cache => 'guest.test.test' ), q{}, 'the cache itself fetches from upstream' );
    }
    like( $said, qr/guest\.test\.test is the fetch cache/, 'and says so' );

    my $again = q{};
    {
        local *STDOUT;
        open( STDOUT, '>', \$again ) or die $!;
        is( $distro->cache_uri( %fleet, cache => 'guest.test.test:8080' ), q{}, 'on whatever port it was named with' );
    }

    like(
        exception { $distro->cache_uri( %fleet, cache => 'nowhere.test.test' ) },
        qr/No address for 'nowhere\.test\.test'.*cache: http:\/\/nowhere\.test\.test/s,
        'a name nothing assigns an address to dies, saying how to name it as a URL'
    );
};

Test::NoWarnings::had_no_warnings();

done_testing;
