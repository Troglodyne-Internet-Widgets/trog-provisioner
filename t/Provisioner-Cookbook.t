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

subtest 'where _base and a domain disagree, _base wins' => sub {
    my $conf = {
        _base      => { ntp => { pool => 'base.pool' } },
        'one.test' => { ntp => { pool => 'domain.pool' } },
    };

    is( Provisioner::Cookbook->domain_config( 'one.test', $conf )->{ntp}{pool}, 'base.pool', 'which is what a provision has always done with it' );
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

    # A domain may add to the data configuration; where it contradicts _base,
    # domain_config's answer is the one a provision would use.
    is( Provisioner::Cookbook->data_config( 'own.test', $conf )->{to}, '/opt/domains', 'a domain does not get to move the install dir out from under _base' );

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

    # _base wins the merge, so writing a placeholder over something it supplies
    # would be silently discarded rather than stopping anything.
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

done_testing();
