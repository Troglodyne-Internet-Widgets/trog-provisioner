#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Cookbook.t - the catalog: what recipes exist, and what a config for one looks like

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};

use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use File::Temp();
use File::Slurper::Temp();

use Provisioner::Cookbook();

subtest 'configuration() reads recipes.yaml and the recipes.d beside it' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", <<'YAML' );
_base:
    data:
        from: /opt/data
        to: /opt/domains
_shared:
    one.test:
        - two.test
one.test:
    ntp:
    mariadb:
        version: '10.11'
YAML

    mkdir "$dir/recipes.d";
    File::Slurper::Temp::write_text( "$dir/recipes.d/two.test.yaml", <<'YAML' );
_base:
    data:
        from: /somewhere/else
_shared: {}
two.test:
    ntp:
YAML

    Provisioner::Cookbook->forget();
    my $conf = Provisioner::Cookbook->configuration("$dir/recipes.yaml");

    is( $conf->{_base}{data}{from}, '/opt/data', 'the base survives a domain file that also names one' );
    is_deeply( $conf->{_shared}{'one.test'}, ['two.test'], 'and so does _shared' );
    ok( exists $conf->{'one.test'}, 'the domain in recipes.yaml is there' );
    ok( exists $conf->{'two.test'}, 'and the one in recipes.d' );
    is( $conf->{'one.test'}{mariadb}{version}, '10.11', 'with what it was configured with' );

    is_deeply( Provisioner::Cookbook->configuration("$dir/nosuch.yaml"), {}, 'a configuration that is not there is empty, not fatal' );
};

subtest 'a domain file adds to recipes.yaml rather than overruling it' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "one.test:\n    ntp:\n        pool: base.pool\n" );
    mkdir "$dir/recipes.d";
    File::Slurper::Temp::write_text( "$dir/recipes.d/one.test.yaml", "one.test:\n    ntp:\n        pool: domain.pool\n        iburst: 1\n" );

    Provisioner::Cookbook->forget();
    my $conf = Provisioner::Cookbook->configuration("$dir/recipes.yaml");

    is( $conf->{'one.test'}{ntp}{pool},   'base.pool', 'the value both files carry is the one recipes.yaml gave it' );
    is( $conf->{'one.test'}{ntp}{iburst}, 1,           'and what only the domain file says is added' );
};

subtest 'configuration() is read once and remembered' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "one.test:\n    ntp:\n" );

    Provisioner::Cookbook->forget();
    my $first = Provisioner::Cookbook->configuration("$dir/recipes.yaml");

    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "two.test:\n    ntp:\n" );
    is_deeply( Provisioner::Cookbook->configuration("$dir/recipes.yaml"), $first, 'the file is not re-read under a running command' );

    Provisioner::Cookbook->forget();
    ok( exists Provisioner::Cookbook->configuration("$dir/recipes.yaml")->{'two.test'}, 'and forget() makes it read again' );
};

subtest 'remember() seats what a run resolved, so recipes read that' => sub {

    # The installation's own directory, not a tempdir of its own: domain_config
    # with no configuration reads Trog::Config's path, so seating anywhere else
    # is seating under one key and reading from another.
    my $dir = $ENV{TROG_PROVISIONER_CONFIG};
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "a.test:\n    pdns:\n        api_key: 'secret:g/e/password'\n" );

    Provisioner::Cookbook->forget();
    is( Provisioner::Cookbook->domain_config('a.test')->{pdns}{api_key}, 'secret:g/e/password', 'the file says where the password is' );

    # bin/new_config resolves into a clone, so what it remembered stays the
    # reference -- and a recipe reading a sibling through domain_config rendered
    # that reference into the file meant to authenticate with it.
    my $resolved = { 'a.test' => { pdns => { api_key => 'REAL' } } };
    Provisioner::Cookbook->remember( "$dir/recipes.yaml", $resolved );

    is( Provisioner::Cookbook->domain_config('a.test')->{pdns}{api_key}, 'REAL', 'after seating, a recipe reads what the run resolved' );

    # A copy, not the caller's structure.  bin/new_config seats what it resolved
    # and then keeps editing it -- folding _base into the domain it is building,
    # then deleting _base outright.  Holding the reference meant a later reader
    # lost the inheritance, invisibly for the domain being built and not at all
    # invisibly for a domain layered onto another, which asks about its host.
    $resolved->{'a.test'}{pdns}{api_key} = 'CHANGED-AFTERWARDS';
    delete $resolved->{'a.test'}{pdns}{soa};
    is( Provisioner::Cookbook->domain_config('a.test')->{pdns}{api_key}, 'REAL', 'and editing it afterwards does not reach what was seated' );

    # And it is remembered the way anything else is: keyed by resolved path, and
    # dropped by forget rather than outliving the command that seated it.
    Provisioner::Cookbook->forget();
    is( Provisioner::Cookbook->domain_config('a.test')->{pdns}{api_key}, 'secret:g/e/password', 'and forget() puts it back to what is on disk' );
};

subtest 'domain_config folds _base into the domain, the way a provision reads it' => sub {
    my $conf = {
        _base => {
            _global => { user => 'www-data' },
            data    => { from => '/opt/data', to => '/opt/domains' },
            ntp     => { pool => 'base.pool' },
        },
        'one.test' => {
            _global => { user   => 'someone-else' },
            ntp     => { iburst => 1 },
            nginx   => {},
        },
    };

    my $one = Provisioner::Cookbook->domain_config( 'one.test', $conf );

    is( $one->{ntp}{pool},   'base.pool', 'what _base configures a recipe with reaches the domain' );
    is( $one->{ntp}{iburst}, 1,           'and what the domain adds is kept' );
    ok( exists $one->{nginx}, 'along with a recipe only the domain asks for' );
    is( $one->{data}{from}, '/opt/data', 'and the data configuration comes with it' );

    # _global merges the other way round -- the domain's own wins -- so it is
    # not this method's to answer.
    ok( !exists $one->{_global}, 'the global section is not part of it' );

    is_deeply( $conf->{'one.test'}{ntp}, { iburst => 1 }, 'the configuration it was handed is not written into' );

    is_deeply(
        Provisioner::Cookbook->domain_config( undef, $conf )->{ntp}, { pool => 'base.pool' },
        'with no domain it is what _base says, which is what a domain gets by default'
    );
    is_deeply(
        Provisioner::Cookbook->domain_config( 'nosuch.test', $conf )->{ntp}, { pool => 'base.pool' },
        'and a domain nothing configures gets the same'
    );
};

subtest 'where _base and a domain disagree, the domain wins' => sub {
    my $conf = {
        _base      => { ntp => { pool => 'base.pool', iburst => 1 } },
        'one.test' => { ntp => { pool => 'domain.pool' } },
    };

    # _base is a base of defaults.  It took _base's side until this was fixed,
    # so a domain could not override anything _base named and the value it wrote
    # was discarded without a word -- see the account in domain_config.
    my $one = Provisioner::Cookbook->domain_config( 'one.test', $conf );
    is( $one->{ntp}{pool}, 'domain.pool', 'the domain value is the one that survives' );

    # Key by key, not block for block: saying one thing about a recipe does not
    # throw away everything else _base said about it.
    is( $one->{ntp}{iburst}, 1, 'and the rest of what _base said about that recipe is still there' );
};

subtest 'a list in _base is added to rather than replaced' => sub {
    my $conf = {
        _base      => { adminconfig => { pkgs => [qw{vim tig}] } },
        'one.test' => { adminconfig => { pkgs => ['emacs'] } },
    };

    # Every Hash::Merge behavior concatenates arrays, including the one this
    # used to have, so fixing the precedence did not change this and no
    # precedence could.  Asserted rather than left to be discovered: it is the
    # one place _base does not behave the way the rest of it now does, and it
    # decides whether a list belongs in _base at all.
    is_deeply(
        Provisioner::Cookbook->domain_config( 'one.test', $conf )->{adminconfig}{pkgs},
        [qw{vim tig emacs}],
        'both, in that order'
    );
};

subtest 'host_of names the guest a domain is layered onto' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", <<'YAML' );
_shared:
    host.test:
        - tenant.test
        - other.test
host.test:
    pdns:
tenant.test:
    letsencrypt:
alone.test:
    letsencrypt:
YAML

    Provisioner::Cookbook->forget();

    is( scalar Provisioner::Cookbook->host_of('tenant.test'), 'host.test', 'a domain built onto another names that machine' );
    is( scalar Provisioner::Cookbook->host_of('other.test'),  'host.test', 'and so does the second one on it' );

    # The distinction every caller turns on.  A recipe asks this to decide
    # whether to read a sibling's configuration rather than its own, so a domain
    # with a machine of its own has to answer nothing rather than answer itself.
    #
    # scalar, because this returns nothing rather than undef -- in the list is()
    # takes, nothing would vanish and shift the arguments along.
    is( scalar Provisioner::Cookbook->host_of('alone.test'), undef, 'a domain with a machine of its own is layered onto nothing' );
    is( scalar Provisioner::Cookbook->host_of('host.test'),  undef, 'and neither is the host itself' );
    is( scalar Provisioner::Cookbook->host_of(undef),        undef, 'and asking about no domain at all is not fatal' );

    # A configuration to work from rather than the one the environment names:
    # bin/new_config resolved the secrets in its copy and passes that.
    is(
        scalar Provisioner::Cookbook->host_of( 'x.test', { _shared => { 'y.test' => ['x.test'] } } ),
        'y.test',
        'a caller can hand it the configuration it means'
    );

    is( scalar Provisioner::Cookbook->host_of( 'x.test', {} ), undef, 'and one with no _shared layers nothing onto anything' );

    Provisioner::Cookbook->forget();
};

subtest 'the data source, and a domain inside it' => sub {
    my $conf = {
        _base       => { data => { from => '/opt/data', to => '/opt/domains' } },
        'one.test'  => { ntp  => {} },
        'own.test'  => { data => { to => '/srv' } },
        'none.test' => { ntp  => {} },
    };

    is_deeply( Provisioner::Cookbook->data_config( undef, $conf ), { from => '/opt/data', to => '/opt/domains' }, 'what every domain gets' );
    is( Provisioner::Cookbook->data_dir( 'one.test', $conf ), '/opt/data/one.test', 'and the directory one of them owns' );

    # Where a domain contradicts _base, domain_config's answer is the one a
    # provision would use -- and that is now the domain's, _base being a base of
    # defaults.  Which also makes the two spellings agree: install_dir in
    # _global has always been the domain's to override, and this is the older
    # one it falls back to.
    is( Provisioner::Cookbook->data_config( 'own.test', $conf )->{to},   '/srv',      'a domain can put its install dir somewhere else' );
    is( Provisioner::Cookbook->install_dir( 'own.test', $conf ),         '/srv',      'and install_dir agrees, reading through to it' );
    is( Provisioner::Cookbook->data_config( 'own.test', $conf )->{from}, '/opt/data', 'without disturbing what _base said about the rest' );

    is( Provisioner::Cookbook->data_dir( undef,      $conf ), undef, 'no domain, no directory' );
    is( Provisioner::Cookbook->data_dir( 'one.test', {} ),    undef, 'and none when nothing says where the data source is' );
    is( Provisioner::Cookbook->data_config( 'none.test', {} ), undef, 'which is undef rather than an error' );
};

subtest 'the shelf has the recipes on it' => sub {
    my @names = Provisioner::Cookbook->names();

    ok( scalar @names > 20, 'there are a good few' );
    is_deeply( [ sort @names ], \@names, 'sorted, so a listing is stable' );
    ok( ( grep { $_ eq 'mariadb' } @names ), 'mariadb is one of them' );

    # It lives in lib/Provisioner/, not lib/Provisioner/Recipe/, because
    # everything in the latter is discovered and loaded as a recipe.
    ok( !( grep { $_ eq 'Cookbook' } @names ), 'and the cookbook is not a recipe' );
};

subtest 'implementations of an interface' => sub {

    # What lets bin/new_config satisfy a substitutable dependency: a
    # recipe can say it needs something that answers a dns-01 challenge without
    # naming the one that happens to exist.
    my @dns = Provisioner::Cookbook->implementations('Provisioner::DNSRecipe');
    is_deeply( [@dns], [qw{pdns registrar}], 'the DNS interface has its two, sorted' );

    # names() prunes the recipes that direct a build, and those implement
    # interfaces too -- every distro recipe is one.  Asked of names alone this
    # answered that nothing implements DistroRecipe, which is a lie that would
    # have read as "no such capability here".
    my @distro = Provisioner::Cookbook->implementations('Provisioner::DistroRecipe');
    ok( ( grep { $_ eq 'ubuntu' } @distro ), 'and a director counts as an implementation' );

    is_deeply( [ Provisioner::Cookbook->implementations('No::Such::Interface') ], [], 'something nothing implements is empty rather than fatal' );

    # Asked once a process: which classes inherit from what is a fact about the
    # code, not about a configuration.
    my @again = Provisioner::Cookbook->implementations('Provisioner::DNSRecipe');
    is_deeply( [@again], [@dns], 'and the answer is stable' );
};

subtest 'has() and load()' => sub {
    ok( Provisioner::Cookbook->has('ntp'),           'a real one' );
    ok( !Provisioner::Cookbook->has('nosuchrecipe'), 'and one that is not' );

    # Nothing that could reach the filesystem outside the recipe directory.
    ok( !Provisioner::Cookbook->has('../Cookbook'), 'no traversal' );
    ok( !Provisioner::Cookbook->has(undef),         'no undef' );
    ok( !Provisioner::Cookbook->has(''),            'no empty string' );

    is( Provisioner::Cookbook->load('ntp'), 'Provisioner::Recipe::ntp', 'loads and names the class' );
    isa_ok( Provisioner::Cookbook->load('ntp'), 'Provisioner::Recipe' );

    my $err = exception { Provisioner::Cookbook->load('nosuchrecipe') };
    like( $err, qr/No[ ]recipe[ ]named[ ]'nosuchrecipe'/, 'says which name it did not know' );
    like( $err, qr/bin\/recipes/,                         'and where to find the ones it does' );
};

subtest 'abstract() reads the file rather than loading it' => sub {
    like( Provisioner::Cookbook->abstract('ntp'), qr/\S/, 'ntp says what it is for' );
    is( Provisioner::Cookbook->abstract('nosuchrecipe'), undef, 'and a missing one says nothing' );

    my @missing = grep { !defined Provisioner::Cookbook->abstract($_) } Provisioner::Cookbook->names();
    is_deeply( \@missing, [], 'every recipe has an ABSTRACT line' ) or diag "no abstract: @missing";
};

subtest 'properties() reads what the validator reads, and nothing else' => sub {
    is_deeply( Provisioner::Cookbook->properties( { properties => { a => {} } } ), { a => {} }, 'properties' );

    # Deliberately not 'parameters'.  OpenAPIv3 ignores it, so offering those
    # fields in a scaffold would claim the recipe checks something it does not.
    is_deeply( Provisioner::Cookbook->properties( { parameters => { b => {} } } ), {}, 'not parameters' );
    is_deeply( Provisioner::Cookbook->properties( {} ),                            {}, 'neither' );
    is_deeply( Provisioner::Cookbook->properties(undef),                           {}, 'nothing at all' );
};

# --- Scaffolding -------------------------------------------------------------
# Against a made-up recipe, so that editing a real one cannot quietly change
# what these assert.
{

    package Provisioner::Recipe::t_scaffold;
    our @ISA = ('Provisioner::Recipe');    ## no critic (ClassHierarchies::ProhibitExplicitISA) -- a class declared in the test, with no file behind it

    sub args {
        return (
            type       => 'object',
            required   => [qw{needed defaulted nested listed}],
            properties => {
                needed    => { type => 'string' },
                defaulted => { type => 'string', default => 'a default' },
                optional  => { type => 'string' },
                opt_dflt  => { type => 'string', default => 'optional default' },
                listed    => { type => 'array',  items   => { type => 'string' } },
                nested    => {
                    type       => 'object',
                    required   => [qw{inner}],
                    properties => {
                        inner    => { type => 'string' },
                        inner_op => { type => 'string' },
                    },
                },
                bag => { type => 'object', additionalProperties => { type => 'string' } },

                # Answered by whatever builds the guest rather than by an
                # operator: the storage volume it made, the MAC it assigned.
                computed => { type => 'string', readOnly => 1 },
            },
        );
    }
}

sub scaffold_of {
    my (%opts) = @_;
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine( load => sub { 'Provisioner::Recipe::t_scaffold' } );
    return Provisioner::Cookbook->scaffold( 't_scaffold', %opts );
}

subtest 'a scaffold is the smallest thing that could work' => sub {
    my ( $config, @todo ) = scaffold_of();

    is( $config->{defaulted}, 'a default',                        'a required field with a default gets it' );
    is( $config->{needed},    Provisioner::Cookbook->PLACEHOLDER, 'and one without gets a placeholder' );

    ok( !exists $config->{optional}, 'optional fields are left out' );
    ok(
        !exists $config->{opt_dflt},
        'including ones with defaults, so the recipe default keeps applying rather than being frozen here'
    );

    is_deeply(
        $config->{nested}, { inner => Provisioner::Cookbook->PLACEHOLDER },
        'a required object is scaffolded through, required fields only'
    );
    is_deeply( $config->{listed}, [ Provisioner::Cookbook->PLACEHOLDER ], 'an array gets one item to copy' );

    is_deeply(
        [ sort @todo ], [qw{t_scaffold.listed[0] t_scaffold.needed t_scaffold.nested.inner}],
        'and the paths that need a human come back, defaults not among them'
    );
};

subtest 'all => 1 is the full menu' => sub {
    my ($config) = scaffold_of( all => 1 );

    is( $config->{opt_dflt},         'optional default',                 'optional fields appear, with their defaults' );
    is( $config->{optional},         Provisioner::Cookbook->PLACEHOLDER, 'and without' );
    is( $config->{nested}{inner_op}, Provisioner::Cookbook->PLACEHOLDER, 'through nested objects too' );
};

subtest 'a readOnly field is never offered to fill in' => sub {
    my ($full) = scaffold_of( all => 1 );
    ok( !exists $full->{computed}, 'not even on the full menu, whatever builds the guest having answered it already' );

    my ( $config, @todo ) = scaffold_of();
    ok( !exists $config->{computed},                      'nor in the smallest thing that could work' );
    ok( !( grep { index( $_, 'computed' ) >= 0 } @todo ), 'and not among the paths that need a human' );
};

subtest 'provided fields are left alone' => sub {

    # There is nothing to fill in when _base supplies it, and asking is how a
    # generated file grows a field pinning what the fleet was meant to decide.
    my ( $config, @todo ) = scaffold_of( provided => { needed => 'from _base' } );

    ok( !exists $config->{needed},                      'not written' );
    ok( !( grep { index( $_, 'needed' ) >= 0 } @todo ), 'and not asked about' );
    is( $config->{defaulted}, 'a default', 'the rest is unaffected' );
};

subtest 'a recipe that needs nothing gets nothing' => sub {
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine( load => sub { 'Provisioner::Recipe' } );    # args() returns ()

    my ( $config, @todo ) = Provisioner::Cookbook->scaffold('anything');
    is( $config, undef, 'undef, which is how the config files spell it: a bare key' );
    is_deeply( \@todo, [], 'and nothing to do' );
};

# A dependency graph made up here too, so that editing a real recipe cannot
# quietly change what these assert.  t_requirer wants three things: one nothing
# supplies, one it supplies itself, and an interface the depsolver resolves.
{

    package Provisioner::Recipe::t_requirer;
    our @ISA = ('Provisioner::Recipe');    ## no critic (ClassHierarchies::ProhibitExplicitISA) -- a class declared in the test, with no file behind it

    sub required_recipes {
        return (
            t_dep       => sub { () },
            t_satisfied => sub { ( needed => 'from the requirer' ) },
        );
    }
}

{

    package Provisioner::Recipe::t_dep;
    our @ISA = ('Provisioner::Recipe');    ## no critic (ClassHierarchies::ProhibitExplicitISA)

    sub required_recipes {
        return ( t_deep => sub { () } );
    }
    sub args { return ( type => 'object', required => [qw{secret}], properties => { secret => { type => 'string' } } ) }
}

{

    package Provisioner::Recipe::t_satisfied;
    our @ISA = ('Provisioner::Recipe');    ## no critic (ClassHierarchies::ProhibitExplicitISA)

    sub args { return ( type => 'object', required => [qw{needed}], properties => { needed => { type => 'string' } } ) }
}

{

    package Provisioner::Recipe::t_deep;
    our @ISA = ('Provisioner::Recipe');    ## no critic (ClassHierarchies::ProhibitExplicitISA)

    sub args { return ( type => 'object', required => [qw{buried}], properties => { buried => { type => 'string' } } ) }
}

{

    package Provisioner::Recipe::t_thrower;
    our @ISA = ('Provisioner::Recipe');    ## no critic (ClassHierarchies::ProhibitExplicitISA)

    # What tcms does: builds a path out of options bin/new_config passes to the
    # sub and this walk has none of.
    sub required_recipes {
        return ( t_dep => sub { die "no install_dir to build a path from\n" } );
    }
}

sub dependencies_of {
    my ( $named, %opts ) = @_;
    my $mock = Test::MockModule->new('Provisioner::Cookbook');

    # By name, because this fixture has several recipes in it rather than one.
    $mock->redefine( load => sub { my ( undef, $name ) = @_; return "Provisioner::Recipe::$name" } );

    # A domain is required rather than defaulted, so a caller with no real one
    # says which bogus one it means.
    return Provisioner::Cookbook->scaffold_dependencies( $named, domain => 'd.test', %opts );
}

subtest 'a dependency nobody named still says what it wants' => sub {
    my ( $blocks, @todo ) = dependencies_of( ['t_requirer'] );

    is_deeply( $blocks->{t_dep}, { secret => Provisioner::Cookbook->PLACEHOLDER }, 'a block to hold the value' );
    ok( ( grep { $_ eq 't_dep.secret' } @todo ), 'and the path comes back to be printed' ) or diag "todo: @todo";
};

subtest 'what the requirer supplies is not asked for twice' => sub {
    my ( $blocks, @todo ) = dependencies_of( ['t_requirer'] );

    ok( !exists $blocks->{t_satisfied}, 'no block for a dependency its requirer covered' );
    is_deeply( [ grep { m/\At_satisfied/ } @todo ], [], 'and nothing to fill in for it' );
};

subtest 'the walk reaches a dependency of a dependency' => sub {
    my ( $blocks, @todo ) = dependencies_of( ['t_requirer'] );

    is_deeply( $blocks->{t_deep}, { buried => Provisioner::Cookbook->PLACEHOLDER }, 'reached through t_dep' );
    ok( ( grep { $_ eq 't_deep.buried' } @todo ), 'and reported with the rest' );
};

subtest 'resolve_dependencies closes the list over what its recipes require' => sub {
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine( load => sub { my ( undef, $name ) = @_; return "Provisioner::Recipe::$name" } );

    my %conf = ( t_requirer => {} );
    my ( $modules, $builders ) = Provisioner::Cookbook->resolve_dependencies(
        modules     => ['t_requirer'],
        domain_conf => \%conf,
        distro      => 'ubuntu',
        provisioner => {
            template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
            output_dir    => File::Temp::tempdir( CLEANUP => 1 ),
        },
        domain => 'd.test',
    );

    ok( ( grep { $_ eq 't_dep' } @$modules ),  'what a recipe requires is added to the list' );
    ok( ( grep { $_ eq 't_deep' } @$modules ), 'and what that one requires in turn' );

    # The point of doing this once rather than twice: the dependency ends up
    # configured out of what asked for it, not merely present.
    is( $conf{t_satisfied}{needed}, 'from the requirer', 'and is configured out of what asked for it' );

    # Returned rather than rebuilt: bin/new_config uses these same objects for
    # the is_module filter, the tenancy check and the render loop.
    ok( $builders->{t_dep}, 'the builders come back for the caller to reuse' );

    # The order is the build's, and it is the whole reason a dependency is named
    # again every time something requires it: lastuniq keeps the last mention,
    # which puts it after everything that dragged it in.  A fragment may not
    # assume its dependency has already run, and grafanasyslog creates its paths
    # root-owned because of it -- so an inversion here breaks a guest rather
    # than a test.
    my %at;
    my $i = 0;
    $at{$_} = $i++ for @$modules;

    cmp_ok( $at{t_requirer}, '<', $at{t_dep},  'a dependency comes after the recipe that required it' );
    cmp_ok( $at{t_dep},      '<', $at{t_deep}, 'and one reached through it comes after that' );

    is( scalar @$modules, scalar keys %at, 'and the list comes back deduplicated, so callers need not' );
};

subtest 'an interface is resolved rather than passed along' => sub {

    # Which recipe answers for one is the interface's to say -- this only holds
    # it to being a recipe that exists and implements what was asked for.
    my $chosen = Provisioner::Cookbook->resolve_substitutable_dependency(
        interface      => 'Provisioner::DNSRecipe',
        domain_conf    => {},
        requiring_conf => {},
        domain         => 'd.test',
    );

    my @known = Provisioner::Cookbook->implementations('Provisioner::DNSRecipe');
    ok( ( grep { $_ eq $chosen } @known ), "resolved to $chosen, which implements it" );

    my $err = exception {
        Provisioner::Cookbook->resolve_substitutable_dependency(
            interface      => 'Provisioner::NoSuchInterface',
            domain_conf    => {},
            requiring_conf => {},
            domain         => 'd.test',
        );
    };
    like( $err, qr/will[ ]not[ ]load/, 'and an interface that is not one says so' );
};

subtest 'a recipe the caller already named is left to the caller' => sub {
    my ($blocks) = dependencies_of( [qw{t_requirer t_dep}] );

    ok( !exists $blocks->{t_dep}, 'no second block for a recipe already scaffolded' );
    ok( exists $blocks->{t_deep}, 'though what that one requires is still followed' );
};

subtest 'a recipe that cannot say what it wants is named, not skipped' => sub {
    my $err = exception { dependencies_of( ['t_thrower'] ) };

    # Its sub reads a global it was not handed.  Skipping the dependency would
    # leave a build that refuses later for a reason nothing here mentioned, so
    # both this and bin/new_config stop and say which recipe could not answer.
    ok( $err, 'the walk refuses rather than carrying on without it' );

    # First, that the refusal is the one this wrote.  warnings FATAL => 'all'
    # makes an uninitialized value in the message itself the exception, so a
    # missing domain replaced the whole sentence with a complaint about the line
    # building it -- and the three assertions below merely said "doesn't match",
    # never that there was no message to match against.
    unlike( $err, qr/uninitialized/, 'and the refusal is a sentence, not a warning from building one' );

    like( $err, qr/t_thrower/,              'naming the recipe that could not answer' );
    like( $err, qr/t_dep/,                  'and what it was asked about' );
    like( $err, qr/_global[ ]in[ ]recipes/, 'and where the configuration it wanted comes from' );

    # And a caller that named no domain at all is refused rather than defaulted
    # into.  Depsolving without knowing what is being provisioned is not a state
    # to carry on from, and a plausible-looking stand-in would hide it.
    my $nameless = exception {
        Provisioner::Cookbook->resolve_dependencies( modules => ['t_requirer'], domain_conf => {} );
    };
    like( $nameless, qr/needs[ ]the[ ]domain/, 'a walk with no domain is refused outright' );
};

subtest 'defaults are copied, not shared' => sub {
    my ($one) = scaffold_of();
    my ($two) = scaffold_of();
    push @{ $one->{listed} }, 'mutated';
    is( scalar @{ $two->{listed} }, 1, 'one scaffold cannot reach into the next' );
};

# --- Finding what is left ----------------------------------------------------
subtest 'placeholders_in walks the whole structure' => sub {
    my $ph = Provisioner::Cookbook->PLACEHOLDER;

    is_deeply(
        [
            Provisioner::Cookbook->placeholders_in(
                {
                    mariadb => { root_pw => $ph, version => '10.11', flags => [ 'ok', $ph ] },
                    ufw     => undef,
                    nested  => { a => { b => $ph } },
                }
            )
        ],
        [qw{mariadb.flags[1] mariadb.root_pw nested.a.b}],
        'hashes, arrays and undefs alike'
    );

    is_deeply(
        [ Provisioner::Cookbook->placeholders_in( { a => 1, b => 'fine' } ) ], [],
        'and says nothing when there is nothing left'
    );

    is_deeply( [ Provisioner::Cookbook->placeholders_in($ph) ], [''], 'a bare placeholder is its own path' );
};

subtest 'every real recipe can be loaded and scaffolded' => sub {

    my @broken;
    foreach my $name ( Provisioner::Cookbook->names() ) {
        eval {
            my ( $config, @todo ) = Provisioner::Cookbook->scaffold($name);
            Provisioner::Cookbook->spec($name);
            1;
        } or push @broken, "$name: $@";
    }
    is_deeply( \@broken, [], 'all of them' ) or diag join "\n", @broken;
};

subtest 'no recipe declares its fields somewhere the validator will not look' => sub {

    # An object schema spells its fields "properties".  Spell it "parameters"
    # and OpenAPIv3 skips the lot: the recipe looks validated, accepts anything,
    # and says nothing.  Seven did.  This is why they do not any more.
    my @wrong;
    foreach my $name ( Provisioner::Cookbook->names() ) {
        my %spec = Provisioner::Cookbook->spec($name);
        push @wrong, map { "$name: $_" } stray_parameters( \%spec, q{} );
    }
    is_deeply( \@wrong, [], 'every schema says properties' ) or diag join "\n", @wrong;
};

# Anywhere in a schema that a "parameters" key sits where "properties" belongs.
sub stray_parameters {
    my ( $node, $path ) = @_;

    my $ref = ref $node;
    return map { stray_parameters( $node->[$_], "$path\[$_]" ) } 0 .. $#$node if $ref eq 'ARRAY';
    return () unless $ref eq 'HASH';

    my @found;
    push @found, ( $path eq q{} ? '(top level)' : $path ) if exists $node->{parameters};
    push @found, map { stray_parameters( $node->{$_}, $path eq q{} ? $_ : "$path.$_" ) } sort keys %$node;
    return @found;
}

subtest 'where a domain lives is _global to say, not the data recipe' => sub {
    my $conf = {
        _base        => { _global => { install_dir => '/srv/domains', data_source => '/srv/data' } },
        'own.test'   => { _global => { install_dir => '/elsewhere' } },
        'plain.test' => {},
    };

    is( Provisioner::Cookbook->install_dir( 'plain.test', $conf ), '/srv/domains', 'what _base says' );
    is( Provisioner::Cookbook->install_dir( 'own.test',   $conf ), '/elsewhere',   'and a domain may say otherwise' );
    is( Provisioner::Cookbook->data_source( 'plain.test', $conf ), '/srv/data', 'likewise the source' );

    # It used to be read out of data's `to`, so a configuration written before
    # the move has to go on working.
    my $legacy = { _base => { data => { from => '/opt/data', to => '/opt/domains' } }, 'a.test' => {} };
    is( Provisioner::Cookbook->install_dir( 'a.test', $legacy ), '/opt/domains', 'falling back to what data says' );
    is( Provisioner::Cookbook->data_source( 'a.test', $legacy ), '/opt/data',    'both halves of it' );

    # _global wins where they disagree: that is the point of the move.
    my $both = {
        _base    => { _global => { install_dir => '/srv/domains' }, data => { to => '/opt/domains' } },
        'a.test' => {},
    };
    is( Provisioner::Cookbook->install_dir( 'a.test', $both ), '/srv/domains', 'and _global is the one that counts' );

    # A path to render is harmless to guess at.  Where the teardown sweeps is
    # not, so that one says nothing rather than pointing at a directory nobody
    # named.
    is( Provisioner::Cookbook->install_dir( 'a.test', {} ), '/opt/domains', 'install_dir has a default' );
    is( Provisioner::Cookbook->data_source( 'a.test', {} ), undef,          'and data_source deliberately has none' );
};

subtest 'the recipes that direct a build are not offered as things to put on one' => sub {
    my %named = map { $_ => 1 } Provisioner::Cookbook->names();

    foreach my $director ( Provisioner::Cookbook->directors() ) {
        ok( !$named{$director},                                 "names() does not offer $director" );
        ok( Provisioner::Cookbook->has($director),              "but has() still finds $director" );
        ok( defined Provisioner::Cookbook->abstract($director), "and it says what it is for" );
    }

    ok( $named{nginx}, 'while an ordinary recipe is offered' );
};

subtest 'a distribution is a directory of recipes, and is found by being one' => sub {
    my @distros = Provisioner::Cookbook->distros();

    ok( scalar( grep { $_ eq 'ubuntu' } @distros ), 'ubuntu is a distribution here' );
    is_deeply( [@distros], [ sort @distros ], 'and they come back sorted' );

    # Read off the directory rather than listed anywhere, so adding a
    # distribution is adding files.
    foreach my $distro (@distros) {
        ok( Provisioner::Cookbook->has($distro), "$distro has a distro recipe of its own, not just a directory" );
    }
};

subtest 'load with a distribution' => sub {
    is( Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' ), 'Provisioner::Recipe::Ubuntu::nginx', 'a recipe with a version for this distribution' );
    is( Provisioner::Cookbook->load( 'nginx', distro => 'Ubuntu' ), 'Provisioner::Recipe::Ubuntu::nginx', 'however it is capitalized' );
    is( Provisioner::Cookbook->load( 'nginx', distro => 'nosuch' ), 'Provisioner::Recipe::nginx',         'and the recipe itself where there is no version for it' );

    # Absence is the only thing that falls back.  A subclass that does not
    # compile, or one that forgot its parent, must take the run down rather than
    # quietly leaving the guest with the base class's empty deps().
    is( Provisioner::Cookbook->load( 'nginx', distro => '../../evil' ), 'Provisioner::Recipe::nginx', 'and a distribution name that is not one is not a path to load from' );
};

subtest 'the defaults a schema declares, for the callers that fill fields in themselves' => sub {
    my %vm = Provisioner::Cookbook->defaults('vm');

    # bin/new_config writes these into provision.conf and bin/new_guest writes
    # them into a domain block; both read them from here so a guest that says
    # nothing and a guest scaffolded by hand are the same guest.
    is( $vm{memory}, 8092, 'memory' );
    is( $vm{cpus},   4,    'cpus' );
    ok( $vm{size} > 0, 'and a disk size' );

    # Only fields that declare one: a field with no default is the operator's
    # to supply, and reporting undef for it would read as an answer.
    ok( !exists $vm{disk_cache}, 'a field with no default is not offered one' );
    ok( !exists $vm{image},      'nor a required field' );
};

subtest 'fetch_hosts: every host any recipe downloads from, once each' => sub {
    my %declared;
    foreach my $name ( Provisioner::Cookbook->names ) {
        $declared{$_}++ for Provisioner::Cookbook->load($name)->fetch_hosts;
    }

    my @hosts = Provisioner::Cookbook->fetch_hosts;
    is_deeply( \@hosts, [ sort keys %declared ], 'what each recipe names, sorted, and each once' );
    ok( ( grep { $_ eq 'www.cpan.org' } @hosts ), 'CPAN among them, which the perl recipe names' );

    # The cache writes each into a regex and a certificate.
    my @bad = grep { !m/\A(?:[[:lower:]\d](?:[[:lower:]\d-]*[[:lower:]\d])?\.)+[[:lower:]\d](?:[[:lower:]\d-]*[[:lower:]\d])?\z/ } @hosts;    ## no critic (RegularExpressions::ProhibitComplexRegexes)
    is_deeply( \@bad, [], 'every one of them a plain, lowercase host name' );
};

subtest 'configured_fetch_hosts: what the domains this installation has will actually reach' => sub {

    # A configuration of its own, on a path nothing has read yet: configuration()
    # remembers each file by path, so a test that wrote into one already read
    # would be asserting against the answer from before it wrote.
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    mkdir "$dir/recipes.d";
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "_base:\n  _global:\n    distro: ubuntu\n" );
    File::Slurper::Temp::write_text(
        "$dir/recipes.d/somewhere.test.yaml",
        "somewhere.test:\n  koan:\n    repo_url: \"https://gitea.internal/o/koan.git\"\n  tcms: ~\n"
    );

    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;
    my @configured = Provisioner::Cookbook->configured_fetch_hosts;

    ok( ( grep { $_ eq 'gitea.internal' } @configured ), 'a host only a repo_url names' );
    ok( ( grep { $_ eq 'github.com' } @configured ),     'and the default host of a recipe that configures nothing' );

    # The point of the method: the class-level list cannot see the first of
    # those, because it is asked with no configuration at all.
    my %class = map { $_ => 1 } Provisioner::Cookbook->fetch_hosts;
    ok( !$class{'gitea.internal'}, 'which fetch_hosts, asked of the class, does not' );

    is_deeply( [@configured], [ sort @configured ], 'sorted' );
    is( scalar( grep { $_ eq 'github.com' } @configured ), 1, 'and once each, however many domains name it' );
};

subtest 'configured_fetch_hosts copes with a configuration that is not there' => sub {

    # fetchcache asks this while building its schema, which the unit tests do
    # against a scratch directory with nothing in it.
    local $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 );
    is_deeply( [ Provisioner::Cookbook->configured_fetch_hosts ], [], 'no configuration, no hosts, no exception' );
};

subtest 'configured_fetch_hosts names a recipe that cannot answer, rather than leaving its hosts out' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    mkdir "$dir/recipes.d";
    File::Slurper::Temp::write_text( "$dir/recipes.yaml",                  "_base:\n  _global:\n    distro: ubuntu\n" );
    File::Slurper::Temp::write_text( "$dir/recipes.d/somewhere.test.yaml", "somewhere.test:\n  koan:\n    repo_url: \"https://gitea.internal/o/koan.git\"\n" );

    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;
    my $koan = Test::MockModule->new('Provisioner::Recipe::koan');
    $koan->redefine( fetch_hosts => sub { die "no idea\n" } );

    my $err = exception { Provisioner::Cookbook->configured_fetch_hosts };
    like( $err, qr/The[ ]koan[ ]recipe[ ]could[ ]not[ ]say[ ]which[ ]hosts[ ]somewhere\.test[ ]fetches[ ]from/, 'names the recipe and the domain' );      ## no critic (RegularExpressions::ProhibitComplexRegexes)
    like( $err, qr/no[ ]idea/,                                                                                  'and passes on what the recipe said' );
};

done_testing();
