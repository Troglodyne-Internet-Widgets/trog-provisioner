#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Provisioner-Cookbook.t - the catalogue: what recipes exist, and what a config for one looks like

=cut

use Test::More;
use Test::MockModule qw{strict};

use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

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

    # Every Hash::Merge behaviour concatenates arrays, including the one this
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

subtest 'has() and load()' => sub {
    ok( Provisioner::Cookbook->has('ntp'),           'a real one' );
    ok( !Provisioner::Cookbook->has('nosuchrecipe'), 'and one that is not' );

    # Nothing that could reach the filesystem outside the recipe directory.
    ok( !Provisioner::Cookbook->has('../Cookbook'), 'no traversal' );
    ok( !Provisioner::Cookbook->has(undef),         'no undef' );
    ok( !Provisioner::Cookbook->has(''),            'no empty string' );

    is( Provisioner::Cookbook->load('ntp'), 'Provisioner::Recipe::ntp', 'loads and names the class' );
    isa_ok( Provisioner::Cookbook->load('ntp'), 'Provisioner::Recipe' );

    eval { Provisioner::Cookbook->load('nosuchrecipe') };
    like( $@, qr/No recipe named 'nosuchrecipe'/, 'says which name it did not know' );
    like( $@, qr/bin\/recipes/,                   'and where to find the ones it does' );
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
    our @ISA = ('Provisioner::Recipe');

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

    # A recipe may compute a default by asking the internet -- garage asks
    # GitHub for the current release.  Scaffolding has to work without a
    # network, and a test suite has no business making the call, so there is
    # not one to make.
    my $http = Test::MockModule->new('HTTP::Tiny');
    $http->redefine( get => sub { { success => 0, status => 599, content => '' } } );

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
    my $http = Test::MockModule->new('HTTP::Tiny');
    $http->redefine( get => sub { { success => 0, status => 599, content => '' } } );

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
    is( Provisioner::Cookbook->load( 'nginx', distro => 'Ubuntu' ), 'Provisioner::Recipe::Ubuntu::nginx', 'however it is capitalised' );
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

done_testing();
